defmodule Ssm.Ssh.ScriptSharedHomeTest do
  @moduledoc """
  `set_authorized_keyfile <login> <ssh_user>` refuses a login that is not the
  SSH user but resolves to the SSH user's home (a uid-0 alias such as `toor`
  sharing root's home): its file is the one holding ssm's own key, and two
  logins writing one file would replace each other's keys.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  setup do
    setup!()
  end

  defp root_home(ctx), do: Path.join(ctx.dir, "root")

  test "a uid-0 alias sharing root's home is refused, root's file untouched", ctx do
    passwd_entry(ctx, "toor", 0, 0, root_home(ctx))
    before = File.read!(ctx.root_keys)

    assert {out, 1} = write(ctx, ["toor", "root"], "ssh-ed25519 OTHER x\n")
    assert out =~ "Keyfile is unsafe (shared_home)"
    assert File.read!(ctx.root_keys) == before
  end

  test "an alias whose home is a symlink to root's home is refused too", ctx do
    link = Path.join(ctx.dir, "toorhome")
    File.ln_s!(root_home(ctx), link)
    passwd_entry(ctx, "toor", 0, 0, link)
    before = File.read!(ctx.root_keys)

    assert {out, 1} = write(ctx, ["toor", "root"], "ssh-ed25519 OTHER x\n")
    assert out =~ "unsafe (shared_home)"
    assert File.read!(ctx.root_keys) == before
  end

  test "the SSH user's own login is written", ctx do
    assert {_, 0} = write(ctx, ["root", "root"], "ssh-ed25519 SSMKEY ssm\nssh-ed25519 NEW y\n")
    assert File.read!(ctx.root_keys) =~ "ssh-ed25519 NEW y"
  end

  test "a login with its own home is written", ctx do
    home = add_user(ctx, "alice")

    assert {_, 0} = write(ctx, ["alice", "root"], "ssh-ed25519 A x\n")
    assert File.read!(Path.join(home, ".ssh/authorized_keys")) =~ "ssh-ed25519 A x"
  end

  test "without the SSH user argument the write is refused: the check is never skipped",
       ctx do
    passwd_entry(ctx, "toor", 0, 0, root_home(ctx))
    before = File.read!(ctx.root_keys)

    for args <- [["toor"], ["toor", ""]] do
      assert {out, 1} = write(ctx, args, "ssh-ed25519 OTHER x\n")
      assert out =~ "unsafe (ssh_user)"
    end

    assert File.read!(ctx.root_keys) == before
  end

  test "an SSH user unknown to getent refuses the write (alias check impossible)", ctx do
    home = add_user(ctx, "alice")

    assert {out, 1} = write(ctx, ["alice", "no-such-user"], "ssh-ed25519 A x\n")
    assert out =~ "unsafe (ssh_user)"
    refute File.exists?(Path.join(home, ".ssh"))
  end
end
