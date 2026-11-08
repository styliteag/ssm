defmodule Ssm.Diffs.SyncRunner do
  @moduledoc """
  Owner of the manual sync (diff page "Sync", per-row sync, "Sync all",
  `POST /api/v2/diffs/{host_id}/sync`):
  runs `Ssm.Diffs.sync_host_reported/2` and writes its audit entry
  (`Ssm.Diffs.SyncAudit`) in a task under `Ssm.Diffs.TaskSupervisor`, not
  linked to the page — closing the tab mid-sync no longer kills a
  half-written sync before its audit entry. Like `Ssm.Diffs.RevocationSync`,
  sync and audit run under the host's `Ssm.Hosts.WriteLock`.

  Per host the state is idle → running(run) → idle
  (`Ssm.Diffs.SyncRunner.State`, kept in this process): a run claims only
  idle hosts, a host already running is reported back as busy and not
  synced a second time; each host is freed as soon as its sync and audit are
  done, the rest when the run ends or crashes. The caller of `run/3` waits
  for the result (a reply message); if the caller dies, the run still
  finishes and audits.

  The `/api/v2` sync (`SsmWeb.Api.DiffController`) runs here too, as the
  token subject: a busy host is answered 409 SYNC_RUNNING with `Retry-After`.
  """

  use GenServer

  require Logger

  alias Ssm.Diffs
  alias Ssm.Diffs.SyncAudit
  alias Ssm.Diffs.SyncRunner.State
  alias Ssm.Hosts.Host
  alias Ssm.Hosts.WriteLock

  @empty_report %{written: [], skipped: [], ignored: []}

  @type outcome :: {:ok, list()} | {:error, term()}
  @type result :: %{results: [{Host.t(), outcome()}], busy: [Host.t()]}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Sync `hosts` as `actor` (the audit actor) and wait for the result:
  `{:ok, %{results: [{host, outcome}], busy: [host]}}` — `outcome` as
  returned by `SyncAudit.log/3`, `busy` the hosts another run already
  syncs (not touched) — or `{:error, {:crashed, reason}}` when the run
  itself died. Hosts are synced one after another. Option `:client` (SSH
  client, default `Ssm.Ssh`).
  """
  @spec run([Host.t()], String.t(), keyword()) :: {:ok, result()} | {:error, {:crashed, term()}}
  def run(hosts, actor, opts \\ []) do
    client = Keyword.get(opts, :client, Ssm.Ssh)
    runner = GenServer.whereis(__MODULE__)
    monitor = Process.monitor(runner)

    try do
      case GenServer.call(runner, {:start, hosts, actor, client, self()}) do
        {:ok, nil, busy} -> {:ok, %{results: [], busy: busy}}
        {:ok, run, busy} -> await(run, busy, monitor)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc "`:idle` or `{:running, run}` for one host."
  @spec status(integer()) :: :idle | {:running, reference()}
  def status(host_id), do: GenServer.call(__MODULE__, {:status, host_id})

  defp await(run, busy, monitor) do
    receive do
      {__MODULE__, ^run, {:ok, results}} -> {:ok, %{results: results, busy: busy}}
      {__MODULE__, ^run, {:error, _} = error} -> error
      {:DOWN, ^monitor, :process, _pid, reason} -> {:error, {:crashed, reason}}
    end
  end

  ## Server

  @impl true
  def init(:ok), do: {:ok, %{hosts: %{}, tasks: %{}}}

  @impl true
  def handle_call({:start, hosts, actor, client, reply_to}, _from, state) do
    run = make_ref()
    {claimed_ids, busy_ids, held} = State.claim(state.hosts, Enum.map(hosts, & &1.id), run)
    pick = fn ids -> hosts |> Enum.uniq_by(& &1.id) |> Enum.filter(&(&1.id in ids)) end

    case pick.(claimed_ids) do
      [] ->
        {:reply, {:ok, nil, pick.(busy_ids)}, state}

      claimed ->
        task =
          Task.Supervisor.async_nolink(Ssm.Diffs.TaskSupervisor, fn ->
            execute(run, claimed, actor, client)
          end)

        tasks = Map.put(state.tasks, task.ref, {run, reply_to})
        {:reply, {:ok, run, pick.(busy_ids)}, %{state | hosts: held, tasks: tasks}}
    end
  end

  def handle_call({:status, host_id}, _from, state),
    do: {:reply, State.status(state.hosts, host_id), state}

  @impl true
  def handle_cast({:host_done, run, host_id}, state),
    do: {:noreply, %{state | hosts: State.release(state.hosts, host_id, run)}}

  @impl true
  def handle_info({ref, results}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, {:ok, results})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    Logger.warning("manual sync run crashed: #{inspect(reason)}")
    {:noreply, finish(state, ref, {:error, {:crashed, reason}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, ref, reply) do
    {{run, reply_to}, tasks} = Map.pop(state.tasks, ref)
    send(reply_to, {__MODULE__, run, reply})
    %{state | hosts: State.release_run(state.hosts, run), tasks: tasks}
  end

  ## The run (task under Ssm.Diffs.TaskSupervisor)

  defp execute(run, hosts, actor, client) do
    Enum.map(hosts, fn host ->
      outcome = sync_one(host, actor, client)
      GenServer.cast(__MODULE__, {:host_done, run, host.id})
      {host, outcome}
    end)
  end

  # every outcome is audited, a crash of one host's sync too
  defp sync_one(%Host{} = host, actor, client) do
    WriteLock.run(host.id, fn ->
      SyncAudit.log(actor, host, guarded_sync(client, host))
    end)
  end

  defp guarded_sync(client, host) do
    Diffs.sync_host_reported(client, host.id)
  rescue
    error -> crashed(host, Exception.message(error))
  catch
    :exit, reason -> crashed(host, inspect(reason))
  end

  defp crashed(host, message) do
    Logger.warning("manual sync of host #{host.id} crashed: #{message}")
    {{:error, {:crashed, message}}, @empty_report}
  end
end
