defmodule SsmWeb.OIDCController do
  @moduledoc """
  `/auth/oidc/{login,callback,backchannel-logout}` (oidc-client-v1 §3, §7,
  §8). All three answer 404 while OIDC is off. Callback errors show one
  generic message; the reason code goes to the audit log, never tokens,
  codes or secrets.
  """

  use SsmWeb, :controller

  require Logger

  alias Ssm.Activity
  alias Ssm.OIDC.{Backchannel, Config, Flow}
  alias Ssm.RateLimit
  alias SsmWeb.UserAuth

  @generic "Single sign-on failed. Please try again or contact an administrator."
  @session_keys ~w(oidc_state oidc_nonce oidc_verifier)a

  plug :require_oidc
  plug :rate_limit

  def login(conn, _params) do
    case Flow.start(callback_url()) do
      {:ok, url, pending} ->
        conn
        |> put_session(:oidc_state, pending.state)
        |> put_session(:oidc_nonce, pending.nonce)
        |> put_session(:oidc_verifier, pending.verifier)
        |> redirect(external: url)

      {:error, :provider_unavailable} ->
        fail(conn, :provider_unavailable, nil)
    end
  end

  def callback(conn, params) do
    pending = pending(conn)
    conn = drop_pending(conn)

    with {:ok, code} <- check_params(params, pending),
         {:ok, login} <- Flow.finish(code, pending, callback_url()) do
      Activity.log(%{
        activity_type: "auth",
        action: "oidc.login",
        target: "login",
        actor_username: login.operator.name,
        details: %{role: login.operator.role, amr: login.amr, sub: login.operator.oidc_subject}
      })

      UserAuth.log_in_operator(conn, login, Config.get().session_max_hours)
    else
      {:error, {reason, sub}} -> fail(conn, reason, sub)
    end
  end

  def backchannel_logout(conn, params) do
    case Backchannel.handle(params["logout_token"]) do
      {:ok, %{sub: sub, sid: sid}} ->
        Activity.log(%{
          activity_type: "auth",
          action: "oidc.backchannel_logout",
          target: "login",
          actor_username: "oidc",
          details: %{sub: sub, sid: sid}
        })

        conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "")

      {:error, reason} ->
        Logger.warning("OIDC back-channel logout refused: #{reason}")
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(400, "")
    end
  end

  defp pending(conn) do
    %{
      state: get_session(conn, :oidc_state),
      nonce: get_session(conn, :oidc_nonce),
      verifier: get_session(conn, :oidc_verifier)
    }
  end

  defp drop_pending(conn), do: Enum.reduce(@session_keys, conn, &delete_session(&2, &1))

  # State is single use (dropped above) and compared in constant time.
  defp check_params(%{"error" => _}, _pending), do: {:error, {:provider_error, nil}}

  defp check_params(%{"code" => code, "state" => state}, %{state: expected} = pending)
       when is_binary(code) and is_binary(state) and is_binary(expected) do
    if is_binary(pending.nonce) and is_binary(pending.verifier) and
         Plug.Crypto.secure_compare(state, expected),
       do: {:ok, code},
       else: {:error, {:bad_state, nil}}
  end

  defp check_params(_params, _pending), do: {:error, {:bad_state, nil}}

  defp fail(conn, reason, sub) do
    Activity.log(%{
      activity_type: "auth",
      action: "oidc.login_refused",
      target: "login",
      actor_username: "anonymous",
      details: %{reason: reason, sub: sub}
    })

    conn
    |> put_flash(:error, @generic)
    |> redirect(to: ~p"/sign-in")
  end

  defp callback_url, do: url(~p"/auth/oidc/callback")

  defp require_oidc(conn, _opts) do
    if Config.enabled?() do
      conn
    else
      conn |> send_resp(404, "Not Found") |> halt()
    end
  end

  defp rate_limit(conn, _opts) do
    case RateLimit.hit({:oidc, RateLimit.client_key(conn.remote_ip)}, 30, 60) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end
