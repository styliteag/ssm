defmodule Ssm.SecurityLog do
  @moduledoc """
  Machine-readable security log for CrowdSec: one JSON object per line on
  stdout, the same format as the other apps of the suite:

      {"type":"auth_failure","app":"ssm","ts":"2026-11-06T10:00:00.000000Z","ip":"203.0.113.7","reason":"bad_password","path":"/sign-in"}

  Written through `Logger` (metadata `security_log: true`) into a handler
  of its own (`install/0`, at application start) that prints only the
  message, so the line starts with `{"type":"auth_failure"` whatever the
  default formatter prints; the default handler drops these events.
  `config :ssm, :security_log_stdout, false` (tests) leaves the handler
  out; `ExUnit.CaptureLog` still sees the lines.

  `ip` is the real client IP (`conn.remote_ip` after
  `SsmWeb.Plugs.TrustedProxies`). The line never holds a password, token,
  username or e-mail address. Reasons:

    * `bad_password` – wrong username or password (web form,
      `/api/v2/auth/login`)
    * `bad_token` – invalid refresh token (`/api/v2/auth/refresh`) or an
      invalid, expired or revoked mctl contract token
    * `locked` – refused by the login throttle (`Ssm.LoginThrottle`), the
      mctl failure limit or the OIDC request limit
    * `oidc_failed` – single sign-on callback or back-channel logout
      refused
  """
  require Logger

  @handler :ssm_security_log
  @reasons ~w(bad_password bad_token locked oidc_failed)

  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "Writes one `auth_failure` line for the request `conn`."
  @spec auth_failure(Plug.Conn.t(), String.t()) :: :ok
  def auth_failure(%Plug.Conn{} = conn, reason) when reason in @reasons do
    line =
      encode(%{
        type: "auth_failure",
        app: "ssm",
        ts: DateTime.utc_now() |> DateTime.to_iso8601(),
        ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
        reason: reason,
        path: conn.request_path
      })

    Logger.warning(line, security_log: true)
  end

  # fixed key order keeps the line greppable and the parser simple
  defp encode(event) do
    fields =
      Enum.map_join(~w(type app ts ip reason path)a, ",", fn key ->
        Jason.encode!(Atom.to_string(key)) <> ":" <> Jason.encode!(Map.fetch!(event, key))
      end)

    "{" <> fields <> "}"
  end

  @doc """
  Adds the stdout handler for security lines and keeps them out of the
  default handler. Idempotent.
  """
  def install do
    _ = :logger.add_handler_filter(:default, :no_security_log, {&__MODULE__.drop/2, nil})
    if Application.get_env(:ssm, :security_log_stdout, true), do: add_handler(), else: :ok
  end

  defp add_handler do
    case :logger.add_handler(@handler, :logger_std_h, %{
           config: %{type: :standard_io},
           filter_default: :stop,
           filters: [security_log: {&__MODULE__.only/2, nil}],
           formatter: Logger.Formatter.new(format: "$message\n", metadata: [])
         }) do
      :ok -> :ok
      {:error, {:already_exist, @handler}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def only(%{meta: %{security_log: true}} = event, _), do: event
  def only(_event, _), do: :ignore

  @doc false
  def drop(%{meta: %{security_log: true}}, _), do: :stop
  def drop(_event, _), do: :ignore
end
