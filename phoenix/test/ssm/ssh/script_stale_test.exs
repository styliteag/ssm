defmodule Ssm.Ssh.ScriptStaleTest do
  @moduledoc """
  The listing reports a `sha256` of each file as read; `set_authorized_keyfile
  <login> <ssh_user> <sha256>` aborts (`stale`) when the file is no longer
  what was read, so nothing the user changed meanwhile is overwritten.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  setup do
    ctx = setup!()
    home = add_user(ctx, "alice")
    File.mkdir_p!(Path.join(home, ".ssh"))
    keys = Path.join(home, ".ssh/authorized_keys")
    File.write!(keys, "ssh-rsa OLD x\nssh-rsa ROGUE y\n")
    Map.put(ctx, :keys, keys)
  end

  defp listed_sha(ctx) do
    {out, 0} = run(ctx, ["get_ssh_keyfiles"])
    out |> Jason.decode!() |> Enum.find(&(&1["login"] == "alice")) |> Map.fetch!("sha256")
  end

  test "the listing reports the sha256 of what it read", ctx do
    expected =
      :crypto.hash(:sha256, "ssh-rsa OLD x\nssh-rsa ROGUE y") |> Base.encode16(case: :lower)

    assert listed_sha(ctx) == expected
  end

  test "an unchanged file is written", ctx do
    sha = listed_sha(ctx)
    assert {_, 0} = write(ctx, ["alice", "root", sha], "ssh-rsa OLD x\n")
    assert File.read!(ctx.keys) =~ "ssh-rsa OLD x"
    refute File.read!(ctx.keys) =~ "ROGUE"
  end

  test "a file changed or removed since the read is not written", ctx do
    sha = listed_sha(ctx)
    File.write!(ctx.keys, "ssh-rsa OLD x\nssh-rsa ROGUE y\nssh-rsa ADDED z\n")

    assert {out, 1} = write(ctx, ["alice", "root", sha], "ssh-rsa OLD x\n")
    assert out =~ "(stale)"
    assert File.read!(ctx.keys) =~ "ADDED"

    File.rm!(ctx.keys)
    assert {out, 1} = write(ctx, ["alice", "root", sha], "ssh-rsa OLD x\n")
    assert out =~ "(stale)"
    refute File.exists?(ctx.keys)
  end
end
