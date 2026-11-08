defmodule Ssm.Diffs.SyncScheduler do
  @moduledoc """
  The periodic key check (US-API-08): every `SSM_SYNC_INTERVAL` (default
  15 minutes, `0` or `off` disables) it runs `Ssm.Diffs.HostChecks.sweep/1`
  and so keeps `host_checks` current for the mctl host summaries.

  The interval is jittered by ±10 % so that several ssm instances do not hit
  the same hosts together, and the first sweep waits a random time (at most
  one minute) after boot. A tick that falls into a running sweep is skipped,
  so sweeps never overlap; a sweep that crashes is logged and the next tick
  runs normally. The sweep runs in a task under `Ssm.Diffs.TaskSupervisor`,
  never in this process.

  Each tick also retries the removal-only sync of hosts still "revocation
  pending" (`Ssm.Diffs.RevocationSync.retry_pending/3`, only with
  `SSM_REVOCATION_SYNC=on`, with backoff); a retry that raises is logged.
  """

  use GenServer

  alias Ssm.Diffs.{HostChecks, RevocationSync}

  require Logger

  @default_interval 900
  @min_interval 10
  @jitter 0.1
  @max_initial_delay_ms 60_000

  @doc """
  Parses `SSM_SYNC_INTERVAL`: seconds (`"120"`, `"90s"`), minutes (`"15m"`)
  or hours (`"2h"`); nil or empty is the default (15 minutes); `"0"` and
  `"off"` disable. Anything below 10 seconds or unparsable is an error.
  """
  @spec parse_interval(String.t() | nil) :: {:ok, pos_integer()} | :off | {:error, String.t()}
  def parse_interval(nil), do: {:ok, @default_interval}

  def parse_interval(raw) when is_binary(raw) do
    case raw |> String.trim() |> String.downcase() do
      "" -> {:ok, @default_interval}
      "off" -> :off
      "0" -> :off
      value -> parse_duration(value)
    end
  end

  defp parse_duration(value) do
    with [_, digits, unit] <- Regex.run(~r/^(\d+)([smh]?)$/, value),
         seconds = String.to_integer(digits) * factor(unit),
         true <- seconds >= @min_interval do
      {:ok, seconds}
    else
      _ ->
        {:error,
         "SSM_SYNC_INTERVAL must be seconds, Ns, Nm or Nh of at least #{@min_interval} seconds, 0 or off (got #{inspect(value)})"}
    end
  end

  defp factor("h"), do: 3600
  defp factor("m"), do: 60
  defp factor(_seconds), do: 1

  @doc "`interval_ms` ± `jitter` (a fraction), in whole milliseconds."
  @spec jittered(pos_integer(), float()) :: pos_integer()
  def jittered(interval_ms, jitter) do
    spread = round(interval_ms * jitter)
    interval_ms + :rand.uniform(2 * spread + 1) - spread - 1
  end

  @doc """
  Options: `:interval_ms` (required), `:jitter`, `:initial_delay_ms`,
  `:sweep_fun`, `:retry_fun` (`(state, now_ms, interval_ms -> state)`),
  `:name` (tests).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval_ms)

    state = %{
      interval: interval,
      jitter: Keyword.get(opts, :jitter, @jitter),
      sweep_fun: Keyword.get(opts, :sweep_fun, &HostChecks.sweep/0),
      retry_fun: Keyword.get(opts, :retry_fun, &RevocationSync.retry_pending/3),
      retry: %{},
      task: nil
    }

    delay =
      Keyword.get_lazy(opts, :initial_delay_ms, fn ->
        :rand.uniform(max(min(interval, @max_initial_delay_ms), 1))
      end)

    Process.send_after(self(), :tick, delay)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, jittered(state.interval, state.jitter))
    {:noreply, state |> retry_revocations() |> start_sweep()}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.info("host key check sweep finished: #{inspect(result)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("host key check sweep crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp retry_revocations(%{retry_fun: fun} = state) do
    %{state | retry: fun.(state.retry, System.monotonic_time(:millisecond), state.interval)}
  rescue
    error ->
      Logger.warning("revocation retry failed: #{Exception.message(error)}")
      state
  end

  defp start_sweep(%{task: %Task{}} = state) do
    Logger.debug("host key check sweep still running, tick skipped")
    state
  end

  defp start_sweep(%{sweep_fun: fun} = state) do
    task = Task.Supervisor.async_nolink(Ssm.Diffs.TaskSupervisor, fun)
    %{state | task: task}
  end
end
