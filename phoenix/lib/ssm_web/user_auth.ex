defmodule SsmWeb.UserAuth do
  @moduledoc """
  Session-based authentication: plugs for the controller pipeline and
  `on_mount` hooks for LiveViews (the ../link-shortener user_auth shape).

  There is no account table — the htpasswd file is the credential store, so
  the session carries the username plus a fingerprint of the user's hash
  line. Password change or user removal kills all of that user's sessions on
  their next request. Sessions expire after 7 days (the python stack's
  refresh-token lifetime; its 15-minute access tokens were an artifact of a
  broken refresh path, not a product decision).
  """

  use SsmWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

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
      {:cont, socket}
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

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      user_from_session(session)
    end)
  end

  # Shared session validation for plug and LiveView paths: username present,
  # session young enough, and the htpasswd entry unchanged since login.
  defp user_from_session(session) do
    with username when is_binary(username) <- session["ssm_user"],
         logged_in_at when is_integer(logged_in_at) <- session["logged_in_at"],
         true <- System.os_time(:second) - logged_in_at <= @session_max_age,
         {:ok, fingerprint} <- Htpasswd.entry_fingerprint(htpasswd_path(), username),
         true <- fingerprint == session["pwv"] do
      %{username: username}
    else
      _ -> nil
    end
  end

  defp htpasswd_path, do: Application.get_env(:ssm, :htpasswd_path, ".htpasswd")
end
