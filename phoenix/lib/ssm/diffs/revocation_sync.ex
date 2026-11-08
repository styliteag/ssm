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
  sync runs in a task under `Ssm.Diffs.TaskSupervisor`, one at a time per
  host, only removes lines, is audited as actor `ssm (revocation sync)` with
  `mode: removal_only`, and clears the mark only after full success. When
  off, the mark and the Hosts page badge are the only effect.
  """

  alias Ssm.Diffs
  alias Ssm.Diffs.SyncAudit
  alias Ssm.Hosts

  require Logger

  @actor "ssm (revocation sync)"
  @key {__MODULE__, :hosts}

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
  Run the removal-only sync for one host and audit it; one run per host at a
  time (a later request waits for the running one).
  """
  @spec run(module(), integer()) :: term()
  def run(client \\ Ssm.Ssh, host_id) do
    :global.trans({{__MODULE__, host_id}, self()}, fn ->
      case Hosts.fetch_host(host_id) do
        {:ok, host} ->
          outcome = Diffs.removal_sync_reported(client, host_id)
          SyncAudit.log(@actor, host, outcome, %{mode: "removal_only"})

        {:error, :not_found} ->
          :ok
      end
    end)
  rescue
    error ->
      Logger.warning("revocation sync of host #{host_id} failed: #{Exception.message(error)}")
      {:error, :crashed}
  end
end
