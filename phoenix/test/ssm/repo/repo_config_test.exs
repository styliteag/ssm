defmodule Ssm.Repo.ConfigTest do
  use ExUnit.Case, async: true

  test "SQLite waits for a held write lock instead of failing at once (busy_timeout)" do
    timeout = Ssm.Repo.config()[:busy_timeout]
    assert is_integer(timeout) and timeout >= 15_000
  end
end
