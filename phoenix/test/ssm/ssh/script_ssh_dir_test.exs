defmodule Ssm.Ssh.ScriptSshDirTest do
  @moduledoc """
  `set_authorized_keyfile` for a login without `~/.ssh`: the real script
  creates it as root (0700, owned by the login's uid/gid from getent) — only
  inside a home that exists and is no symlink, and never through a link
  planted at `.ssh`.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  setup do
    setup!()
  end

  test "creates a missing ~/.ssh: 0700, owned by the login's uid and gid, then the file", ctx do
    home = add_user(ctx, "fresh", 1000, 1001)

    assert {_, 0} = write(ctx, "fresh", "ssh-ed25519 GRANTED x\n")

    ssh = File.lstat!(Path.join(home, ".ssh"))
    assert ssh.type == :directory
    assert Bitwise.band(ssh.mode, 0o777) == 0o700
    assert {ssh.uid, ssh.gid} == {1000, 1001}
    assert File.read!(Path.join(home, ".ssh/authorized_keys")) =~ "ssh-ed25519 GRANTED x"
  end

  test "an existing ~/.ssh is left as it is (mode and owner)", ctx do
    home = add_user(ctx, "kept")
    ssh = Path.join(home, ".ssh")
    File.mkdir_p!(ssh)
    File.chmod!(ssh, 0o755)

    assert {_, 0} = write(ctx, "kept", "ssh-ed25519 K x\n")
    assert Bitwise.band(File.lstat!(ssh).mode, 0o777) == 0o755
    assert File.lstat!(ssh).uid == 0
  end

  test "a dangling ~/.ssh symlink is refused, its target never created", ctx do
    home = add_user(ctx, "dangle")
    target = Path.join(ctx.dir, "planted")
    File.ln_s!(target, Path.join(home, ".ssh"))

    assert {out, 1} = write(ctx, "dangle", "ssh-ed25519 ATTACKER x\n")
    assert out =~ "unsafe (ssh_dir)"
    refute File.exists?(target)
  end

  test "a home that is a symlink is refused, nothing is created behind it", ctx do
    victim = Path.join(ctx.dir, "victim")
    File.mkdir_p!(victim)
    link = Path.join(ctx.dir, "linkhome")
    File.ln_s!(victim, link)
    passwd_entry(ctx, "linked", 1000, 1000, link)

    assert {out, 1} = write(ctx, "linked", "ssh-ed25519 ATTACKER x\n")
    assert out =~ "unsafe (home)"
    assert File.ls!(victim) == []
  end

  test "a missing home is refused, nothing is created", ctx do
    home = Path.join(ctx.dir, "home/ghost")
    passwd_entry(ctx, "ghost", 1000, 1000, home)

    assert {out, 1} = write(ctx, "ghost", "ssh-ed25519 K x\n")
    assert out =~ "unsafe (home)"
    refute File.exists?(home)
  end

  test "an unknown login is refused, no /.ssh is created", ctx do
    assert {out, 1} = write(ctx, "nobody-here", "ssh-ed25519 K x\n")
    assert out =~ "unsafe (home)"
    refute File.exists?("/.ssh")
  end

  test "a ~/.ssh swapped for a symlink right after mkdir: no chown, no write through it", ctx do
    home = add_user(ctx, "racer")
    root_ssh = Path.join(ctx.dir, "root/.ssh")
    before = File.read!(ctx.root_keys)

    # the user wins the race: ssm's fresh .ssh is moved away and a link to
    # root's ~/.ssh takes its place before ssm enters it
    fake_bin(ctx, "mkdir", """
    /bin/mkdir "$@" || exit 1
    if [ "$1" = ".ssh" ]; then /bin/mv .ssh .ssh.mine && ln -s "#{root_ssh}" .ssh; fi\
    """)

    assert {out, 1} = write(ctx, "racer", "ssh-ed25519 ATTACKER x\n")
    assert out =~ "unsafe (ssh_dir)"
    assert File.lstat!(root_ssh).uid == 0
    assert File.read!(ctx.root_keys) == before
    assert File.ls!(root_ssh) == ["authorized_keys"]
    assert File.lstat!(Path.join(home, ".ssh.mine")).uid == 0
  end

  test "a host-wide readonly marker stops the write before ~/.ssh is created", ctx do
    home = add_user(ctx, "frozen")
    File.write!(Path.join(ctx.dir, "root/.ssh/system_readonly"), "")

    assert {out, 1} = write(ctx, "frozen", "ssh-ed25519 K x\n")
    assert out =~ "readonly"
    refute File.exists?(Path.join(home, ".ssh"))
  end

  test "a root-owned dir swapped in for the new ~/.ssh is never handed to the user", ctx do
    home = add_user(ctx, "taker")
    # a root-owned directory an admin left in the user's home
    left = Path.join(home, "admin-stuff")
    File.mkdir_p!(left)
    File.write!(Path.join(left, "secret"), "x")

    fake_bin(ctx, "mkdir", """
    /bin/mkdir "$@" || exit 1
    if [ "$1" = ".ssh" ]; then /bin/mv .ssh .ssh.mine && /bin/mv admin-stuff .ssh; fi\
    """)

    assert {out, 1} = write(ctx, "taker", "ssh-ed25519 K x\n")
    assert out =~ "unsafe (ssh_dir)"
    assert File.lstat!(Path.join(home, ".ssh")).uid == 0
  end

  test "a setgid home: the new ~/.ssh inherits g+s and is still accepted", ctx do
    home = add_user(ctx, "sgid")
    File.chmod!(home, 0o2755)

    assert {_, 0} = write(ctx, "sgid", "ssh-ed25519 K x\n")
    ssh = File.lstat!(Path.join(home, ".ssh"))
    assert Bitwise.band(ssh.mode, 0o077) == 0
    assert ssh.uid == 1000
  end

  test "a home whose parent the user can write is refused, nothing created", ctx do
    owned = Path.join(ctx.dir, "userparent")
    File.mkdir_p!(Path.join(owned, "a"))
    {_, 0} = System.cmd("chown", ["1000", owned])
    passwd_entry(ctx, "ownparent", 1000, 1000, Path.join(owned, "a"))

    open = Path.join(ctx.dir, "worldparent")
    File.mkdir_p!(Path.join(open, "b"))
    File.chmod!(open, 0o1777)
    passwd_entry(ctx, "openparent", 1000, 1000, Path.join(open, "b"))

    for {login, home} <- [
          {"ownparent", Path.join(owned, "a")},
          {"openparent", Path.join(open, "b")}
        ] do
      assert {out, 1} = write(ctx, login, "ssh-ed25519 K x\n")
      assert out =~ "unsafe (home)"
      refute File.exists?(Path.join(home, ".ssh"))
    end
  end
end
