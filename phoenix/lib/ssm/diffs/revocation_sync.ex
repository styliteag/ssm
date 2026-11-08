defmodule Ssm.Diffs.RevocationSync do
  @moduledoc """
  The immediate removal-only sync of ADR-0012 §6, opt-in through
  `SSM_REVOCATION_SYNC` (`off`, the default, or `on`): automatic host writes
  stay off unless an operator turns them on.

  When on, every revoking change (a reconcile that removed grant rows, a
  deleted manual row — whatever marks a host "revocation pending" through
  `Ssm.Diffs.Revocations.mark/2`) starts `Ssm.Diffs.removal_sync_reported/2`
  for that host once the change is committed: marks made inside a
  transaction are collected per process and requested by the outermost
  `Ssm.Grants.transaction/1` after its commit (dropped on rollback). Each
  sync runs in a task under `Ssm.Diffs.TaskSupervisor`, under the host's
  `Ssm.Hosts.WriteLock` (one host write at a time), only removes lines, is
  audited as actor `ssm (revocation sync)` with action `sync_revocation`
  (`_partial`, `_failed`) and `mode: removal_only`, and
  clears the mark only after full success. A run that raises or exits (an
  SSH call that timed out) is audited as `sync_revocation_failed`. When off,
  the mark and the Hosts page badge are the only effect.

  Retries (`retry_pending/3`, on every `Ssm.Diffs.SyncScheduler` tick, so
  only while `SSM_SYNC_INTERVAL` is on): a host still pending is synced
  again one interval after its mark, then after 2, 4, … intervals (at most
  16 intervals apart); a new mark restarts the count.
  """

  alias Ssm.Diffs
  alias Ssm.Diffs.{Revocations, SyncAudit}
  alias Ssm.Hosts
  alias Ssm.Hosts.WriteLock
  alias Ssm.Scope

  require Logger

  @actor "ssm (revocation sync)"
  @key {__MODULE__, :hosts}
  @max_backoff 16
  @empty_report %{written: [], skipped: [], ignored: []}

  @doc "Parses `SSM_REVOCATION_SYNC`: nil, empty or `off` → false, `on` → true."
  @spec parse(term()) :: {:ok, boolean()} | {:error, String.t()}
  def parse(nil), do: {:ok, false}

  def parse(raw) when is_binary(raw) do
    case raw |> String.trim() |> String.downcase() do
      value when value in ["", "off"] -> {:ok, false}
      "on" -> {:ok, true}
      _ -> {:error, "SSM_REVOCATION_SYNC must be on or off (got #{inspect(raw)})"}
    end
  end

  def parse(other), do: {:error, "SSM_REVOCATION_SYNC must be on or off (got #{inspect(other)})"}

  @doc "Is the removal-only sync on? An invalid value counts as off."
  @spec enabled?() :: boolean()
  def enabled? do
    case parse(Application.get_env(:ssm, :revocation_sync)) do
      {:ok, on?} -> on?
      {:error, _} -> false
    end
  end

  @doc "Remember a marked host until the surrounding transaction commits."
  @spec collect(integer()) :: :ok
  def collect(host_id) do
    Process.put(@key, [host_id | Process.get(@key, [])])
    :ok
  end

  @doc "After a commit: request the collected hosts."
  @spec flush() :: :ok
  def flush, do: (Process.delete(@key) || []) |> Enum.uniq() |> request()

  @doc "After a rollback: forget the collected hosts."
  @spec discard() :: :ok
  def discard do
    Process.delete(@key)
    :ok
  end

  @doc "Start a removal-only sync for each host (no-op when off)."
  @spec request([integer()]) :: :ok
  def request(host_ids) do
    if enabled?(), do: Enum.each(host_ids, &start/1)
    :ok
  end

  defp start(host_id) do
    case Application.get_env(:ssm, :revocation_sync_runner, :async) do
      :inline ->
        run(host_id)

      :async ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Ssm.Diffs.TaskSupervisor, fn -> run(host_id) end)
    end
  end

  @doc """
  Run the removal-only sync for one host and audit it under the host's
  write lock (`Ssm.Hosts.WriteLock`, shared with every other host write:
  a manual sync, "Remove key", offboarding, forgetting a managed login),
  so a later request waits for whatever runs on that host.
  """
  @spec run(module(), integer()) :: term()
  def run(client \\ Ssm.Ssh, host_id) do
    WriteLock.run(host_id, fn ->
      case Hosts.fetch_host(host_id) do
        {:ok, host} ->
          outcome = Diffs.removal_sync_reported(client, host_id)
          SyncAudit.log(@actor, host, outcome, %{mode: "removal_only"}, "sync_revocation")

        {:error, :not_found} ->
          :ok
      end
    end)
  rescue
    error -> crashed(host_id, Exception.message(error))
  catch
    :exit, reason -> crashed(host_id, "exit: " <> inspect(reason, limit: 20))
  end

  # the crash is audited like a failed sync (best effort): the mark stays
  defp crashed(host_id, text) do
    Logger.warning("revocation sync of host #{host_id} failed: #{text}")

    try do
      with {:ok, host} <- Hosts.fetch_host(host_id) do
        outcome = {{:error, {:crashed, "crashed: " <> text}}, @empty_report}
        SyncAudit.log(@actor, host, outcome, %{mode: "removal_only"}, "sync_revocation")
      end
    rescue
      error -> Logger.warning("revocation sync audit failed: #{Exception.message(error)}")
    end

    {:error, :crashed}
  end

  @doc """
  The hosts to retry now, and the new retry state. `pending` maps each
  marked host to its mark time, `state` is the previous result (`%{}` at
  first), `now_ms` a monotonic time and `base_ms` the interval. A mark not
  seen before waits `base_ms` (its immediate sync ran after the commit);
  each retry doubles the wait, up to #{@max_backoff} × `base_ms`. Hosts no
  longer pending are dropped.
  """
  @spec plan_retries(%{integer() => term()}, map(), integer(), pos_integer()) ::
          {[integer()], map()}
  def plan_retries(pending, state, now_ms, base_ms) do
    pending
    |> Enum.sort()
    |> Enum.reduce({[], %{}}, fn {host_id, mark}, {due, next} ->
      case Map.get(state, host_id) do
        %{mark: ^mark, next_ms: at} = entry when now_ms >= at ->
          attempts = entry.attempts + 1
          wait = base_ms * min(Integer.pow(2, attempts), @max_backoff)

          {[host_id | due],
           Map.put(next, host_id, %{entry | attempts: attempts, next_ms: now_ms + wait})}

        %{mark: ^mark} = entry ->
          {due, Map.put(next, host_id, entry)}

        _new_or_newer_mark ->
          {due, Map.put(next, host_id, %{mark: mark, attempts: 0, next_ms: now_ms + base_ms})}
      end
    end)
    |> then(fn {due, next} -> {Enum.reverse(due), next} end)
  end

  @doc """
  Retry the removal-only sync of hosts still "revocation pending"
  (`plan_retries/4`); returns the new state. Off: nothing, `%{}`.
  """
  @spec retry_pending(map(), integer(), pos_integer()) :: map()
  def retry_pending(state, now_ms, base_ms) do
    if enabled?() do
      pending =
        Scope.global() |> Revocations.pending() |> Map.new(fn {id, p} -> {id, p.inserted_at} end)

      {due, state} = plan_retries(pending, state, now_ms, base_ms)
      request(due)
      state
    else
      %{}
    end
  end
end
