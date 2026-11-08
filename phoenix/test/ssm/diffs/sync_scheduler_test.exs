defmodule Ssm.Diffs.SyncSchedulerTest do
  use ExUnit.Case, async: true

  alias Ssm.Diffs.SyncScheduler

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

      start_supervised!(
        {SyncScheduler,
         name: :sched_retry,
         interval_ms: 20,
         jitter: 0.0,
         initial_delay_ms: 0,
         sweep_fun: fn -> :ok end,
         retry_fun: retry}
      )

      assert_receive {:retry, %{}, 20}, 1000
      assert_receive {:retry, %{ticks: 1}, 20}, 1000
    end

    test "a crashing retry_fun keeps the scheduler running" do
      me = self()

      retry = fn _state, _now, _interval ->
        send(me, :retry)
        raise "db down"
      end

      pid =
        start_supervised!(
          {SyncScheduler,
           name: :sched_retry_crash,
           interval_ms: 20,
           jitter: 0.0,
           initial_delay_ms: 0,
           sweep_fun: fn -> :ok end,
           retry_fun: retry}
        )

      assert_receive :retry, 1000
      assert_receive :retry, 1000
      assert Process.alive?(pid)
    end
  end

  describe "process" do
    test "sweeps on every tick, never two at once" do
      me = self()
      running = :counters.new(2, [])

      sweep = fn ->
        :counters.add(running, 1, 1)
        if :counters.get(running, 1) > 1, do: :counters.put(running, 2, 1)
        send(me, :sweep_start)
        Process.sleep(60)
        :counters.sub(running, 1, 1)
        send(me, :sweep_end)
        %{checked: 0, failed: 0}
      end

      start_supervised!(
        {SyncScheduler,
         name: :sched_test, interval_ms: 20, jitter: 0.0, initial_delay_ms: 0, sweep_fun: sweep}
      )

      assert_receive :sweep_start, 500
      assert_receive :sweep_end, 500
      assert_receive :sweep_start, 500
      assert_receive :sweep_end, 500
      assert :counters.get(running, 2) == 0
    end

    @tag :capture_log
    test "a crashing sweep does not kill the scheduler" do
      me = self()

      sweep = fn ->
        send(me, :ran)
        raise "boom"
      end

      pid =
        start_supervised!(
          {SyncScheduler,
           name: :sched_crash, interval_ms: 20, jitter: 0.0, initial_delay_ms: 0, sweep_fun: sweep}
        )

      assert_receive :ran, 500
      assert_receive :ran, 500
      assert Process.alive?(pid)
    end
  end
end
