defmodule SsmWeb.UserAuth do
  @moduledoc """
  Session-based authentication: plugs for the controller pipeline and
  `on_mount` hooks for LiveViews (the ../link-shortener user_auth shape).

  Two kinds of web user. Local users have no account table — the htpasswd
  file is the credential store (every such user is an admin), so the session
  carries the username plus a fingerprint of the user's hash line; password
  change or user removal kills all of that user's sessions on their next
  request. OIDC users are `Ssm.Accounts.Operator` rows (role admin /
  operator / viewer); their session carries the operator id and an absolute
  expiry, and is checked against the row (disabled, revoked) on every
  request and LiveView mount. Local sessions expire after 7 days (the python stack's
  refresh-token lifetime; its 15-minute access tokens were an artifact of a
  broken refresh path, not a product decision).
  """

  use SsmWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Ssm.Accounts
  alias Ssm.Auth.Htpasswd

  @session_max_age 7 * 24 * 60 * 60

  @doc "Logs the user in: renews the session (fixation defense) and redirects."
  def log_in_user(conn, username) do
    {:ok, fingerprint} = Htpasswd.entry_fingerprint(htpasswd_path(), username)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:ssm_user, username)
    |> put_session(:pwv, fingerprint)
    |> put_session(:logged_in_at, System.os_time(:second))
    |> put_session(:live_socket_id, live_socket_id(username))
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs an OIDC operator in (oidc-client-v1 §7): renews the session and
  records `oidc_sid`, `oidc_sub` and the absolute expiry
  (`OIDC_SESSION_MAX_HOURS`). `login` is `%{operator: _, sid: _}`.
  """
  def log_in_operator(conn, %{operator: operator, sid: sid}, max_hours) do
    user_return_to = get_session(conn, :user_return_to)
    now = System.os_time(:second)

    conn
    |> renew_session()
    |> put_session(:operator_id, operator.id)
    |> put_session(:oidc_sid, sid)
    |> put_session(:oidc_sub, operator.oidc_subject)
    |> put_session(:oidc_started_ms, Accounts.now_ms())
    |> put_session(:oidc_expires_at, now + max_hours * 3600)
    |> put_session(:logged_in_at, now)
    |> put_session(:live_socket_id, operator_socket_id(operator.id))
    |> redirect(to: local_path(user_return_to) || signed_in_path(conn))
  end

  @doc "LiveView socket topic of an operator's sessions (disconnect target)."
  defdelegate operator_socket_id(operator_id), to: Accounts, as: :socket_id

  # Only a stored same-origin path is a valid post-login target.
  defp local_path("/" <> _ = path) do
    if String.starts_with?(path, "//") or String.contains?(path, "\\"), do: nil, else: path
  end

  defp local_path(_), do: nil

  @doc "Logs the user out and disconnects any live sessions."
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      SsmWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/sign-in")
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp live_socket_id(username), do: "ssm_sessions:#{Base.url_encode64(username)}"

  @doc "Plug: assigns `:current_user` (a `%{username: ...}` map) from the session."
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, user_from_session(get_session(conn)))
  end

  @doc "Plug: redirects logged-in users away from auth-only pages (sign-in)."
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: signed_in_path(conn)) |> halt()
    else
      conn
    end
  end

  @doc "Plug: requires an authenticated user, else redirects to sign-in."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/dashboard"

  ## LiveView on_mount hooks

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket |> SsmWeb.ReadOnly.attach() |> watch_oidc_session(session)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
       |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(nil))}
    else
      {:cont, socket}
    end
  end

  # An OIDC session is more than a cookie check at mount: a timer ends the
  # view at the absolute expiry, and every `oidc_recheck_ms` (60 s) the
  # operator row is read again (disabled, revoked, sid revoked, role
  # changed). Back-channel logout and disabling also broadcast a disconnect.
  defp watch_oidc_session(%{assigns: %{current_user: %{source: :oidc}}} = socket, session) do
    if Phoenix.LiveView.connected?(socket) do
      slice = Map.take(session, ~w(operator_id oidc_expires_at oidc_started_ms oidc_sid))
      remaining_ms = max(slice["oidc_expires_at"] - System.os_time(:second), 0) * 1000
      Process.send_after(self(), :oidc_session_expired, min(remaining_ms, 4_000_000_000))
      schedule_recheck()

      Phoenix.LiveView.attach_hook(socket, :oidc_session, :handle_info, fn msg, socket ->
        oidc_info(msg, socket, slice)
      end)
    else
      socket
    end
  end

  defp watch_oidc_session(socket, _session), do: socket

  defp oidc_info(:oidc_session_expired, socket, _slice), do: {:halt, session_ended(socket)}

  defp oidc_info(:oidc_session_recheck, socket, slice) do
    role = socket.assigns.current_user.role

    case user_from_session(slice) do
      %{role: ^role} ->
        schedule_recheck()
        {:halt, socket}

      _ended_or_changed ->
        {:halt, session_ended(socket)}
    end
  end

  defp oidc_info(_msg, socket, _slice), do: {:cont, socket}

  defp schedule_recheck,
    do:
      Process.send_after(
        self(),
        :oidc_session_recheck,
        Application.get_env(:ssm, :oidc_recheck_ms, 60_000)
      )

  defp session_ended(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "Your session has ended. Please sign in again.")
    |> Phoenix.LiveView.redirect(to: ~p"/sign-in")
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      user_from_session(session)
    end)
  end

  # Shared session validation for plug and LiveView paths. An OIDC session
  # names an operator; a local one names an htpasswd user.
  defp user_from_session(%{"operator_id" => id} = session) when is_integer(id),
    do: operator_from_session(id, session)

  defp user_from_session(session), do: local_from_session(session)

  # Local sign-in not switched off (LOCAL_LOGIN=off; the "off without OIDC"
  # safety already turned that into admins_only at boot), username present,
  # session young enough, htpasswd entry unchanged since login. Every
  # htpasswd user is a local admin.
  defp local_from_session(session) do
    with true <- Ssm.OIDC.Config.local_login() != :off,
         username when is_binary(username) <- session["ssm_user"],
         logged_in_at when is_integer(logged_in_at) <- session["logged_in_at"],
         true <- System.os_time(:second) - logged_in_at <= @session_max_age,
         {:ok, fingerprint} <- Htpasswd.entry_fingerprint(htpasswd_path(), username),
         true <- fingerprint == session["pwv"] do
      %{username: username, actor: username, role: "admin", source: :local}
    else
      _ -> nil
    end
  end

  # Operator still exists and is enabled, the absolute lifetime has not
  # passed and no back-channel logout (by sub or by this session's sid)
  # came after the login.
  defp operator_from_session(id, session) do
    with expires when is_integer(expires) <- session["oidc_expires_at"],
         started when is_integer(started) <- session["oidc_started_ms"],
         true <- System.os_time(:second) < expires,
         %{disabled_at: nil} = operator <- Accounts.get_operator(id),
         true <- started > (operator.session_revoked_at || 0),
         false <- Accounts.sid_revoked?(operator.oidc_issuer, session["oidc_sid"]) do
      %{
        username: operator.name,
        actor: Accounts.actor_label(operator),
        role: operator.role,
        source: :oidc,
        operator_id: operator.id
      }
    else
      _ -> nil
    end
  end

  defp htpasswd_path, do: Application.get_env(:ssm, :htpasswd_path, ".htpasswd")
end
