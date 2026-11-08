defmodule Ssm.Diffs.SyncSchedulerTest do
  use ExUnit.Case, async: true

  alias Ssm.Diffs.SyncScheduler

  # Process tests drive ticks by hand (`send(pid, :tick)`): the timers are
  # an hour away, so no test depends on scheduling under load.
  @never 3_600_000

  defp start_scheduler(name, opts) do
    start_supervised!(
      {SyncScheduler,
       [name: name, interval_ms: @never, jitter: 0.0, initial_delay_ms: @never] ++ opts}
    )
  end

  # The sweep task the scheduler runs now (nil when idle).
  defp sweep_task(pid), do: :sys.get_state(pid).task

  # Waits until sweep task `task_pid` has ended (:noproc when it already
  # has) and the scheduler has handled its result or crash.
  defp await_sweep_done(pid, task_pid) do
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 5_000
    await_idle(pid)
  end

  defp await_idle(pid) do
    case sweep_task(pid) do
      nil -> :ok
      %Task{} -> await_idle(pid)
    end
  end

  describe "parse_interval/1" do
    test "seconds, minutes, hours; default 15 minutes; off for 0/off" do
      assert SyncScheduler.parse_interval(nil) == {:ok, 900}
      assert SyncScheduler.parse_interval("") == {:ok, 900}
      assert SyncScheduler.parse_interval("120") == {:ok, 120}
      assert SyncScheduler.parse_interval("15m") == {:ok, 900}
      assert SyncScheduler.parse_interval("2h") == {:ok, 7200}
      assert SyncScheduler.parse_interval("90s") == {:ok, 90}
      assert SyncScheduler.parse_interval("0") == :off
      assert SyncScheduler.parse_interval("off") == :off
    end

    test "garbage and too small values are errors" do
      assert {:error, _} = SyncScheduler.parse_interval("soon")
      assert {:error, _} = SyncScheduler.parse_interval("-5")
      assert {:error, _} = SyncScheduler.parse_interval("5")
    end
  end

  describe "jittered/2" do
    test "stays within plus/minus the jitter fraction" do
      for _ <- 1..200 do
        ms = SyncScheduler.jittered(900_000, 0.1)
        assert ms >= 810_000 and ms <= 990_000
      end
    end

    test "spreads values" do
      assert 1..50
             |> Enum.map(fn _ -> SyncScheduler.jittered(900_000, 0.1) end)
             |> Enum.uniq()
             |> length() > 10
    end
  end

  describe "revocation retries" do
    test "every tick hands the retry state to retry_fun" do
      me = self()

      retry = fn state, now_ms, interval_ms ->
        send(me, {:retry, state, interval_ms})
        Map.put(state, :ticks, Map.get(state, :ticks, 0) + 1) |> Map.put(:now, now_ms)
      end

      pid = start_scheduler(:sched_retry, sweep_fun: fn -> :ok end, retry_fun: retry)

      send(pid, :tick)
      assert_receive {:retry, %{}, @never}, 5_000
      send(pid, :tick)
      assert_receive {:retry, %{ticks: 1}, @never}, 5_000
    end

    @tag :capture_log
    test "a crashing retry_fun keeps the scheduler running" do
      me = self()

      retry = fn _state, _now, _interval ->
        send(me, :retry)
        raise "db down"
      end

      pid = start_scheduler(:sched_retry_crash, sweep_fun: fn -> :ok end, retry_fun: retry)

      send(pid, :tick)
      assert_receive :retry, 5_000
      send(pid, :tick)
      assert_receive :retry, 5_000
      assert Process.alive?(pid)
    end
  end

  describe "process" do
    test "the first tick follows initial_delay_ms" do
      me = self()

      start_supervised!(
        {SyncScheduler,
         name: :sched_first,
         interval_ms: @never,
         jitter: 0.0,
         initial_delay_ms: 0,
         sweep_fun: fn -> send(me, :swept) end,
         retry_fun: fn state, _now, _interval -> state end}
      )

      assert_receive :swept, 5_000
    end

    test "sweeps on every tick, never two at once" do
      me = self()

      sweep = fn ->
        send(me, {:sweep_start, self()})
        receive do: (:go -> :ok)
        %{checked: 0, failed: 0}
      end

      pid =
        start_scheduler(:sched_test,
          sweep_fun: sweep,
          retry_fun: fn state, _now, _interval -> state end
        )

      send(pid, :tick)
      assert_receive {:sweep_start, first}, 5_000

      # a tick while the sweep runs is skipped
      send(pid, :tick)
      assert %Task{pid: ^first} = sweep_task(pid)

      send(first, :go)
      await_sweep_done(pid, first)

      send(pid, :tick)
      assert_receive {:sweep_start, second}, 5_000
      assert second != first
      send(second, :go)
      await_sweep_done(pid, second)

      refute_received {:sweep_start, _}
    end

    @tag :capture_log
    test "a crashing sweep does not kill the scheduler" do
      me = self()

      sweep = fn ->
        send(me, {:ran, self()})
        raise "boom"
      end

      pid =
        start_scheduler(:sched_crash,
          sweep_fun: sweep,
          retry_fun: fn state, _now, _interval -> state end
        )

      send(pid, :tick)
      assert_receive {:ran, first}, 5_000
      await_sweep_done(pid, first)

      send(pid, :tick)
      assert_receive {:ran, second}, 5_000
      await_sweep_done(pid, second)
      assert Process.alive?(pid)
    end
  end
end
