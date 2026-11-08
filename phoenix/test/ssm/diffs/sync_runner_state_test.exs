defmodule Ssm.Diffs.SyncRunner.StateTest do
  @moduledoc """
  The per-host manual sync state of `Ssm.Diffs.SyncRunner`: idle → running(run)
  → idle. A claim takes only idle hosts, a release frees a host only for the
  run that holds it.
  """

  use ExUnit.Case, async: true

  alias Ssm.Diffs.SyncRunner.State

  describe "claim/3" do
    cases = [
      {"all idle: every host is claimed", %{}, [1, 2], {[1, 2], [], %{1 => :a, 2 => :a}}},
      {"one held by another run: it is busy", %{2 => :b}, [1, 2],
       {[1], [2], %{1 => :a, 2 => :b}}},
      {"all held: nothing is claimed", %{1 => :b}, [1], {[], [1], %{1 => :b}}},
      {"held by the same run counts as busy too", %{1 => :a}, [1], {[], [1], %{1 => :a}}},
      {"a host listed twice is claimed once", %{}, [3, 3], {[3], [], %{3 => :a}}},
      {"no hosts", %{}, [], {[], [], %{}}}
    ]

    for {name, state, ids, expected} <- cases do
      @state state
      @ids ids
      @expected expected
      test name do
        assert State.claim(@state, @ids, :a) == @expected
      end
    end
  end

  describe "release/3" do
    cases = [
      {"the holder frees its host", %{1 => :a, 2 => :a}, 1, :a, %{2 => :a}},
      {"another run cannot free it", %{1 => :b}, 1, :a, %{1 => :b}},
      {"an idle host stays idle", %{}, 1, :a, %{}}
    ]

    for {name, state, id, run, expected} <- cases do
      @state state
      @id id
      @run run
      @expected expected
      test name do
        assert State.release(@state, @id, @run) == @expected
      end
    end
  end

  describe "release_run/2" do
    test "frees every host of the run, keeps the others" do
      assert State.release_run(%{1 => :a, 2 => :b, 3 => :a}, :a) == %{2 => :b}
    end
  end

  describe "status/2" do
    test "idle or running with the run" do
      assert State.status(%{}, 1) == :idle
      assert State.status(%{1 => :a}, 1) == {:running, :a}
    end
  end
end
