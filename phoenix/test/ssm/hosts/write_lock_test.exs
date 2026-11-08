defmodule Ssm.Hosts.WriteLockTest do
  @moduledoc """
  `Ssm.Hosts.WriteLock` is re-entrant for the holder: a nested `run/2` (the
  revocation sync around `Diffs.removal_sync_reported/2`) must not release
  the lock the outer `run/2` still holds.
  """

  use ExUnit.Case, async: true

  alias Ssm.Hosts.WriteLock

  test "a nested run keeps the outer lock until the outer run ends" do
    host_id = System.unique_integer([:positive])
    test = self()

    holder =
      spawn(fn ->
        WriteLock.run(host_id, fn ->
          :inner = WriteLock.run(host_id, fn -> :inner end)
          send(test, :inner_done)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :inner_done, 2_000
    other = Task.async(fn -> WriteLock.run(host_id, fn -> :other end) end)
    assert Task.yield(other, 200) == nil

    send(holder, :release)
    assert Task.await(other) == :other
  end
end
