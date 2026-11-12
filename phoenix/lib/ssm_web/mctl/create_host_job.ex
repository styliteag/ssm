defmodule SsmWeb.Mctl.CreateHostJob do
  @moduledoc """
  The work of a `create_host` job (onboarding v2 §4, ADR-0008):

    1. Put `ssm_public_key` (the key ssm logs in with), `username` and
       `limited` (not root, `Ssm.Hosts.limited?/1`) into the job result at once, while the job is `running` — mctl then
       authorizes the key on the host through the dashboard.
    2. Wait `initial_wait_ms` (default 5 s), so mctl can authorize the key
       before the first login: a login that fails counts as an attack for a
       host's login guard (sshguard on pfSense blocks the address after
       three). Then probe the host key and log in
       (`Ssm.Hosts.HostKeys.pin/2`; the probe authenticates). A pre-seeded
       `key_fingerprint` is verified, never trusted on first use: a
       different key fails at once with `host_key_changed`. A failed login
       (`auth_failed`) or a timeout is retried with exponential backoff
       until `config :ssm, :mctl_login_wait` `timeout_ms` (default 10
       minutes) is used up. A refused connection is retried too, but only
       after a failed login of this job: the port was open then, so the
       host has most likely blocked ssm for a while. A refused first
       connection (wrong port) still fails at once.
    3. Learn the machine-id HMAC (`Ssm.Hosts.MachineId`; never fails the job).

  A disabled host is not contacted: the job succeeds with `pin:
  skipped_disabled`. A failed job deletes the host again, so the same
  request can be posted again. A host deleted while the job runs ends it
  as `failed` with `host_deleted` (no rollback, no crash). Clients get a
  short code and a fixed sentence; raw SSH detail goes to the log only.
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
    host_id
    |> guarded_work(principal, job_id)
    |> outcome(host_id, principal)
  end

  # The host may be deleted while the job runs (DELETE /hosts/{id}, the
  # UI): every outcome then is `host_deleted`, and a write that raced the
  # deletion (stale update) must not crash the job.
  defp guarded_work(host_id, principal, job_id) do
    work(host_id, principal, job_id)
  rescue
    Ecto.StaleEntryError -> deleted()
  end

  defp outcome(result, host_id, principal) do
    case {result, Hosts.get_host(host_id)} do
      {_result, nil} ->
        deleted()

      {{:ok, _} = ok, _host} ->
        ok

      {{:error, _code, _message} = failure, _host} ->
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
      base = %{
        "ssm_public_key" => public_key,
        "username" => host.username,
        "limited" => Hosts.limited?(host)
      }

      :ok = JobResult.put(job_id, base)

      ctx = %{
        job_id: job_id,
        username: host.username,
        pin_opts: [actor: Audit.actor(principal), ip: principal.ip],
        wait: Application.fetch_env!(:ssm, :mctl_login_wait)
      }

      deadline = now_ms() + ctx.wait[:timeout_ms]
      initial_wait(ctx)

      host.id
      |> retry(ctx, deadline, 1, ctx.wait[:first_delay_ms], false)
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

  # mctl authorizes the key right after it shows up in the job result
  defp initial_wait(ctx) do
    case Keyword.get(ctx.wait, :initial_wait_ms, 0) do
      ms when ms > 0 ->
        Jobs.progress(
          ctx.job_id,
          "waiting for ssm_public_key to be authorized for #{ctx.username}"
        )

        Process.sleep(ms)

      _ ->
        :ok
    end
  end

  # One login attempt; retryable failures sleep and try again until the
  # deadline. The host is re-read each time (deleted or disabled meanwhile).
  # `auth_failed?`: a login of this job has failed before.
  defp attempt(host, ctx, deadline, n, delay, auth_failed?) do
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
        retry? = retry?(reason, auth_failed?)

        if retry? and now_ms() + delay <= deadline do
          Process.sleep(delay)
          failed? = auth_failed? or code(reason) == "auth_failed"
          retry(host.id, ctx, deadline, n + 1, min(delay * 2, ctx.wait[:max_delay_ms]), failed?)
        else
          if retry?, do: {:error, {:gave_up, reason, n}}, else: error
        end

      ok ->
        ok
    end
  end

  defp retry(host_id, ctx, deadline, n, delay, auth_failed?) do
    case Hosts.get_host(host_id) do
      nil -> {:error, :deleted}
      host -> attempt(host, ctx, deadline, n, delay, auth_failed?)
    end
  end

  @doc """
  Is a failed attempt worth another one? A failed login and a timeout
  always; a refused connection only after a failed login of the same job
  (`auth_failed?`): the port was open, so the host blocks ssm for a while.
  """
  def retry?({:host_key_changed, _}, _auth_failed?), do: false

  def retry?(reason, auth_failed?) do
    code = code(reason)
    code in @retry_codes or (auth_failed? and code == "connect_refused")
  end

  defp code(reason), do: elem(ErrorCode.classify(reason), 0)

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
      case code do
        "auth_failed" ->
          "SSH login as #{ctx.username} still failed after #{waited}: #{text}. " <>
            "Authorize ssm_public_key for #{ctx.username} on the host, then add the host again"

        "connect_refused" ->
          "#{text} after failed logins (#{waited}): the host may block ssm's address " <>
            "(login guard); add the host again later"

        _ ->
          "#{text} (#{waited})"
      end

    {:error, code, message}
  end

  defp finish({:error, reason}, _base, _ctx) do
    {code, message} = ErrorCode.classify(reason)
    Logger.warning("mctl create_host: host key probe failed (#{code}): #{inspect(reason)}")
    {:error, code, message}
  end

  defp deleted, do: {:error, "host_deleted", "the host was deleted while it was being added"}

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
