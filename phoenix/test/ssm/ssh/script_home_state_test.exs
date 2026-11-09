defmodule Ssm.Ssh.ScriptHomeStateTest do
  @moduledoc """
  `get_ssh_keyfiles <login>…` (real `script.sh`): a login ssm asks about
  whose home is not there — an unmounted pool on an inactive HA node, an
  unknown login — comes back with a `home_state` code instead of looking
  like "no keys"; a login whose home is there but has no file stays out.
  """
  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  setup do
    ctx = setup!()
    there = add_user(ctx, "there", 1001, 1001)
    gone = add_user(ctx, "gone", 1002, 1002)
    File.rm_rf!(gone)
    Map.merge(ctx, %{there: there})
  end

  defp listing(ctx, args) do
    {out, 0} = run(ctx, ["get_ssh_keyfiles" | args])
    out |> Jason.decode!() |> Map.new(&{&1["login"], &1})
  end

  test "a missing home and an unknown login are reported, an empty home is not", ctx do
    entries = listing(ctx, ["gone", "nobody-here", "there"])

    assert entries["gone"]["home_state"] == "home_missing"
    assert entries["gone"]["keyfile"] == ""
    assert entries["nobody-here"]["home_state"] == "unknown_login"
    refute Map.has_key?(entries, "there")
  end

  test "without asked logins the listing is unchanged", ctx do
    refute Enum.any?(listing(ctx, []), fn {_login, e} -> Map.has_key?(e, "home_state") end)
  end

  test "an unsafe login argument is ignored", ctx do
    entries = listing(ctx, ["-x", "gone"])
    refute Map.has_key?(entries, "-x")
    assert entries["gone"]["home_state"] == "home_missing"
  end
end
