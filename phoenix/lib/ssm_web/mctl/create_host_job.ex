defmodule SsmWeb.Mctl.CreateHostJob do
  @moduledoc """
  The work of a `create_host` job (onboarding v2 §4, ADR-0008):

    1. Put `ssm_public_key` (the key ssm logs in with) and `username` into
       the job result at once, while the job is `running` — mctl then
       authorizes the key on the host through the dashboard.
    2. Probe the host key and log in (`Ssm.Hosts.HostKeys.pin/2`; the probe
       authenticates). A pre-seeded `key_fingerprint` is verified, never
       trusted on first use: a different key fails at once with
       `host_key_changed`. A failed login (`auth_failed`) or a timeout is
       retried with exponential backoff until `config :ssm,
       :mctl_login_wait` `timeout_ms` (default 10 minutes) is used up.
    3. Learn the machine-id HMAC (`Ssm.Hosts.MachineId`; never fails the job).

  A disabled host is not contacted: the job succeeds with `pin:
  skipped_disabled`. A failed job deletes the host again, so the same
  request can be posted again. Clients get a short code and a fixed
  sentence; raw SSH detail goes to the log only.
  """

  require Logger

  alias MctlContract.Jobs.Ecto, as: Jobs
  alias Ssm.Hosts
  alias Ssm.Hosts.{HostKeys, MachineId}
  alias Ssm.Mctl.JobResult
  alias Ssm.Ssh.ErrorCode
  alias SsmWeb.Mctl.Audit

  @retry_codes ~w(auth_failed timeout)

  @doc "Run the job for `host_id`; the `MctlContract.Jobs.Ecto.run/4` work function."
  @spec run(pos_integer(), map(), String.t()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def run(host_id, principal, job_id) do
    case work(host_id, principal, job_id) do
      {:ok, _} = ok ->
        ok

      {:error, _code, _message} = failure ->
        roll_back(host_id, principal)
        failure
    end
  end

  defp work(host_id, principal, job_id) do
    case Hosts.get_host(host_id) do
      nil -> deleted()
      %{disabled: true} -> {:ok, %{"pin" => "skipped_disabled", "ssh_host_key" => nil}}
      host -> onboard(host, principal, job_id)
    end
  end

  defp onboard(host, principal, job_id) do
    with {:ok, public_key} <- own_key() do
      base = %{"ssm_public_key" => public_key, "username" => host.username}
      :ok = JobResult.put(job_id, base)

      ctx = %{
        job_id: job_id,
        username: host.username,
        pin_opts: [actor: Audit.actor(principal), ip: principal.ip],
        wait: Application.fetch_env!(:ssm, :mctl_login_wait)
      }

      deadline = now_ms() + ctx.wait[:timeout_ms]

      host
      |> attempt(ctx, deadline, 1, ctx.wait[:first_delay_ms])
      |> finish(base, ctx)
    end
  end

  defp own_key do
    case Application.get_env(:ssm, :own_key, Ssm.Ssh.OwnKey).public_key() do
      {:ok, key} ->
        {:ok, key}

      {:error, _} ->
        {:error, "ssm_key_unavailable",
         "ssm has no usable SSH key (SSH_KEY / SSH_KEY_PASSPHRASE); see the server log"}
    end
  end

  # One login attempt; retryable failures sleep and try again until the
  # deadline. The host is re-read each time (deleted or disabled meanwhile).
  defp attempt(host, ctx, deadline, n, delay) do
    if n > 1 do
      Jobs.progress(
        ctx.job_id,
        "waiting for ssm_public_key to be authorized for #{ctx.username} (login attempt #{n})"
      )
    else
      Jobs.progress(ctx.job_id, "probing SSH host key and logging in as #{ctx.username}")
    end

    case HostKeys.pin(host, ctx.pin_opts) do
      {:error, reason} = error ->
        if retry?(reason) and now_ms() + delay <= deadline do
          Process.sleep(delay)
          retry(host.id, ctx, deadline, n + 1, min(delay * 2, ctx.wait[:max_delay_ms]))
        else
          if retry?(reason), do: {:error, {:gave_up, reason, n}}, else: error
        end

      ok ->
        ok
    end
  end

  defp retry(host_id, ctx, deadline, n, delay) do
    case Hosts.get_host(host_id) do
      nil -> {:error, :deleted}
      host -> attempt(host, ctx, deadline, n, delay)
    end
  end

  defp retry?({:host_key_changed, _}), do: false
  defp retry?(reason), do: elem(ErrorCode.classify(reason), 0) in @retry_codes

  defp finish({:ok, status, host}, base, _ctx) do
    # identity-claims-v1: learn the machine-id HMAC now that the key is
    # pinned and SSH is allowed; a failure never fails the job.
    host = MachineId.refresh(host, [])

    {:ok,
     Map.merge(base, %{"pin" => Atom.to_string(status), "ssh_host_key" => host.key_fingerprint})}
  end

  defp finish({:error, {:host_key_changed, %{pinned: pinned, offered: offered}}}, _base, _ctx) do
    {:error, "host_key_changed",
     "host key differs from the pinned one: pinned #{pinned}, offered #{offered.fingerprint}"}
  end

  defp finish({:error, :deleted}, _base, _ctx), do: deleted()

  defp finish({:error, {:gave_up, reason, attempts}}, _base, ctx) do
    {code, text} = ErrorCode.classify(reason)
    Logger.warning("mctl create_host: login gave up (#{code}): #{inspect(reason)}")
    waited = "#{attempts} attempts in #{duration(ctx.wait[:timeout_ms])}"

    message =
      if code == "auth_failed",
        do:
          "SSH login as #{ctx.username} still failed after #{waited}: #{text}. " <>
            "Authorize ssm_public_key for #{ctx.username} on the host, then add the host again",
        else: "#{text} (#{waited})"

    {:error, code, message}
  end

  defp finish({:error, reason}, _base, _ctx) do
    {code, message} = ErrorCode.classify(reason)
    Logger.warning("mctl create_host: host key probe failed (#{code}): #{inspect(reason)}")
    {:error, code, message}
  end

  defp deleted, do: {:error, "not_found", "the host was deleted before its key was pinned"}

  defp roll_back(host_id, principal) do
    with %{} = host <- Hosts.get_host(host_id),
         {:ok, _} <- Hosts.delete_host(host) do
      Audit.host(principal, "create_rolled_back", host)
    end

    :ok
  end

  defp duration(ms) when ms >= 60_000, do: "#{div(ms, 60_000)} min"
  defp duration(ms) when ms >= 1_000, do: "#{div(ms, 1_000)} s"
  defp duration(ms), do: "#{ms} ms"

  defp now_ms, do: System.monotonic_time(:millisecond)
end
