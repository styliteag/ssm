defmodule SsmWeb.MctlAuthHooks do
  @moduledoc """
  Limits and audit for authentication at `/api/mctl/v1`
  (`MctlContract.AuthHooks`), on `Ssm.RateLimit`:

    * failed authentication (invalid, expired or revoked token — not a
      missing one) counts against the client IP (IPv6: its /64); at the
      limit every request from that client
      is `429 rate_limited` with `Retry-After` until the window ends —
      valid tokens included, so a guesser cannot test candidates
    * failures are audited in the activity log (type `auth`) once per client
      and window (`mctl_auth_failed`) and when the limit is reached
      (`mctl_auth_locked`) — never per request, never with the token
    * each token has a request budget per window (`429` beyond it)

  Limits: `config :ssm, :mctl_limits, auth_failures: {count, seconds},
  token_requests: {count, seconds}`. The client IP is `conn.remote_ip`,
  which `SsmWeb.Plugs.TrustedProxies` sets from `X-Forwarded-For` behind a
  configured reverse proxy.
  """

  @behaviour MctlContract.AuthHooks

  alias Ssm.{Activity, RateLimit}

  @defaults [auth_failures: {10, 300}, token_requests: {600, 60}]

  @impl true
  def before_auth(conn) do
    {limit, window} = limits(:auth_failures)

    case RateLimit.check({:mctl_auth_failed, client(conn)}, limit, window) do
      :ok ->
        {:ok, conn}

      {:error, retry_after} ->
        Ssm.SecurityLog.auth_failure(conn, "locked")
        {:error, retry_after}
    end
  end

  # No token at all (probes, health checks, a misconfigured client) is not
  # a guess: not counted, not audited. Only presented-but-bad tokens count.
  @impl true
  def on_auth_failure(_conn, :missing), do: :ok

  def on_auth_failure(conn, reason) do
    Ssm.SecurityLog.auth_failure(conn, "bad_token")
    {limit, window} = limits(:auth_failures)
    ip = ip(conn)
    failures = RateLimit.count({:mctl_auth_failed, client(conn)}, window)

    cond do
      failures == limit -> audit("mctl_auth_locked", ip, reason, failures, window)
      failures == 1 -> audit("mctl_auth_failed", ip, reason, failures, window)
      true -> :ok
    end
  end

  @impl true
  def rate_limit(_conn, %MctlContract.Principal{id: token_id}) do
    {limit, window} = limits(:token_requests)
    RateLimit.hit({:mctl_token, token_id}, limit, window)
  end

  defp limits(kind) do
    :ssm
    |> Application.get_env(:mctl_limits, [])
    |> Keyword.get(kind, Keyword.fetch!(@defaults, kind))
  end

  defp audit(action, ip, reason, failures, window) do
    Activity.log(%{
      activity_type: "auth",
      action: action,
      target: "api/mctl/v1",
      actor_username: "anonymous",
      details: %{ip: ip, reason: reason, failures: failures, window_seconds: window}
    })
  end

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
  defp client(conn), do: RateLimit.client_key(conn.remote_ip)
end
