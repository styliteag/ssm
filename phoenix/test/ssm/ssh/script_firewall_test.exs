defmodule Ssm.Ssh.ScriptFirewallTest do
  @moduledoc """
  OPNsense and pfSense write `authorized_keys` from their configuration.
  There `script.sh` writes the user's keys into the configuration with the
  box's PHP code and lets the box write the file. The box is simulated: a
  fake `php` keeps one file per configuration user, a fake `configctl`
  copies it to the user's `authorized_keys`.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  @old "ssh-ed25519 AAAAOLD admin@laptop"
  @ssm "ssh-ed25519 AAAASSM ssm"
  @new "from=\"10.0.0.1\" ssh-rsa AAAANEW alice"

  setup do
    ctx = setup!()
    File.mkdir_p!(Path.join(ctx.dir, "usr/local/opnsense/version"))
    File.write!(Path.join(ctx.dir, "usr/local/opnsense/version/core"), "{}")
    conf = Path.join(ctx.dir, "fwconf")
    File.mkdir_p!(conf)
    File.write!(Path.join(conf, "users"), "0:root\n2000:orbit\n")
    File.write!(Path.join(conf, "root"), @old <> "\n" <> @ssm)
    File.write!(ctx.root_keys, @old <> "\n" <> @ssm <> "\n")

    fake_bin(ctx, "php", """
    cat >/dev/null
    case "$(pwd)" in */.ssh) echo "php run in a .ssh" >&2; exit 9 ;; esac
    conf="#{conf}"
    case "$SSM_FW_OP" in
      users) cat "$conf/users" ;;
      get) [ -f "$conf/$SSM_FW_USER" ] || exit 3; cat "$conf/$SSM_FW_USER" ;;
      set) [ -f "$conf/$SSM_FW_USER" ] || exit 3; printf "%s" "$SSM_FW_KEYS" > "$conf/$SSM_FW_USER" ;;
    esac\
    """)

    # "configctl auth sync user root": the box writes root's file
    fake_bin(ctx, "configctl", """
    [ -e "#{conf}/no_sync" ] && exit 0
    cat "#{conf}/$4" > "#{ctx.dir}/root/.ssh/authorized_keys"; echo >> "#{ctx.dir}/root/.ssh/authorized_keys"\
    """)

    Map.put(ctx, :conf, conf)
  end

  defp fw_env(ctx), do: [{"SSM_SYSROOT", ctx.dir} | env(ctx)]

  defp fw_run(ctx, args),
    do: System.cmd("sh", [ctx.script | args], env: fw_env(ctx), stderr_to_stdout: true)

  defp fw_write(ctx, login, content) do
    input = Path.join(ctx.dir, "input")
    File.write!(input, content)

    System.cmd(
      "sh",
      ["-c", ~s(sh "$0" set_authorized_keyfile "$1" root < "$2"), ctx.script, login, input],
      env: fw_env(ctx),
      stderr_to_stdout: true
    )
  end

  defp listed(ctx, login) do
    {out, 0} = fw_run(ctx, ["get_ssh_keyfiles"])
    out |> Jason.decode!() |> Enum.find(&(&1["login"] == login))
  end

  test "a user of the configuration is managed, any other login is readonly", ctx do
    home = add_user(ctx, "alice")
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".ssh/authorized_keys"), @old <> "\n")

    assert %{"readonly_condition" => "", "has_pragma" => false} = listed(ctx, "root")

    assert %{"readonly_scope" => "user", "readonly_condition" => reason} = listed(ctx, "alice")
    assert reason =~ "firewall's configuration"

    assert {out, 1} = fw_write(ctx, "alice", @new <> "\n")
    assert out =~ "readonly"
  end

  test "a write goes into the configuration; the box writes the file", ctx do
    assert {_, 0} = fw_write(ctx, "root", @ssm <> "\n" <> @new <> "\n")

    assert File.read!(Path.join(ctx.conf, "root")) == @ssm <> "\n" <> @new
    keys = File.read!(ctx.root_keys)
    assert keys =~ "AAAANEW" and keys =~ "AAAASSM"
    refute keys =~ "AAAAOLD"
    refute keys =~ "Auto-generated"

    # the keys from before are kept once, and the login counts as managed
    ssh = Path.dirname(ctx.root_keys)
    assert [backup] = Path.wildcard(Path.join(ssh, "authorized_keys.backup.*"))
    assert File.read!(backup) =~ "AAAAOLD"
    assert %{"has_pragma" => true} = listed(ctx, "root")

    assert {_, 0} = fw_write(ctx, "root", @ssm <> "\n")
    assert [^backup] = Path.wildcard(Path.join(ssh, "authorized_keys.backup.*"))
  end

  test "a line that is no key line never reaches the configuration", ctx do
    for bad <- [
          "garbage\n",
          @ssm <> "\nc3NoLWVkMjU1MTkgQUFBQQ==\n",
          "# comment\n" <> @ssm <> "\n"
        ] do
      assert {out, 1} = fw_write(ctx, "root", bad)
      assert out =~ "firewall_lines"
    end

    assert File.read!(Path.join(ctx.conf, "root")) == @old <> "\n" <> @ssm
  end

  test "keys the box does not write to the file are taken back", ctx do
    File.touch!(Path.join(ctx.conf, "no_sync"))

    assert {out, 1} = fw_write(ctx, "root", @ssm <> "\n" <> @new <> "\n")
    assert out =~ "put back"
    assert File.read!(Path.join(ctx.conf, "root")) == @old <> "\n" <> @ssm
  end

  test "only the user with the login's name and uid is written, never through a link", ctx do
    home = add_user(ctx, "alice")
    ssh = Path.join(home, ".ssh")
    File.mkdir_p!(ssh)
    File.write!(Path.join(ssh, "authorized_keys"), @old <> "\n")
    File.chown!(ssh, 1000)

    # another user of the configuration has alice's uid: not alice's keys
    File.write!(Path.join(ctx.conf, "users"), "0:root\n1000:bob\n")
    File.write!(Path.join(ctx.conf, "bob"), @old)
    assert {out, 1} = fw_write(ctx, "alice", @new <> "\n")
    assert out =~ "readonly"

    # a uid two users share is never mapped
    File.write!(Path.join(ctx.conf, "users"), "0:root\n1000:alice\n1000:bob\n")
    File.write!(Path.join(ctx.conf, "alice"), @old)
    assert {out, 1} = fw_write(ctx, "alice", @new <> "\n")
    assert out =~ "readonly"

    # alice links her file to root's: the box would write through it
    File.write!(Path.join(ctx.conf, "users"), "0:root\n1000:alice\n")
    File.rm!(Path.join(ssh, "authorized_keys"))
    File.ln_s!(ctx.root_keys, Path.join(ssh, "authorized_keys"))
    assert {out, 1} = fw_write(ctx, "alice", @new <> "\n")
    assert out =~ "unsafe (symlink)"
    assert File.read!(Path.join(ctx.conf, "alice")) == @old
    refute File.read!(ctx.root_keys) =~ "AAAANEW"
  end

  test "keys in the configuration that could not be put back stop the write", ctx do
    File.write!(Path.join(ctx.conf, "root"), "Deprecated: something\n" <> @ssm)
    assert {out, 1} = fw_write(ctx, "root", @ssm <> "\n")
    assert out =~ "firewall_lines"
    assert File.read!(Path.join(ctx.conf, "root")) =~ "Deprecated"
  end

  test "OPNsense without php is readonly for the whole host", ctx do
    File.rm!(Path.join(ctx.dir, "bin/php"))
    env = [{"SSM_SYSROOT", ctx.dir}, {"PATH", Path.join(ctx.dir, "bin") <> ":/usr/bin:/bin"}]
    env = env ++ Enum.reject(env(ctx), fn {k, _} -> k == "PATH" end)

    {out, 0} =
      System.cmd("sh", [ctx.script, "get_ssh_keyfiles"], env: env, stderr_to_stdout: true)

    assert %{"readonly_scope" => "platform", "readonly_condition" => "Product is OPNsense"} =
             out |> Jason.decode!() |> Enum.find(&(&1["login"] == "root"))
  end

  test "pfSense without php stays readonly for the whole host", ctx do
    File.rm_rf!(Path.join(ctx.dir, "usr"))
    File.mkdir_p!(Path.join(ctx.dir, "etc"))
    File.write!(Path.join(ctx.dir, "etc/platform"), "pfSense\n")
    File.rm!(Path.join(ctx.dir, "bin/php"))

    # no php in the PATH at all (the container may have none anyway)
    env = [{"SSM_SYSROOT", ctx.dir}, {"PATH", Path.join(ctx.dir, "bin") <> ":/usr/bin:/bin"}]
    env = env ++ Enum.reject(env(ctx), fn {k, _} -> k == "PATH" end)

    {out, 0} =
      System.cmd("sh", [ctx.script, "get_ssh_keyfiles"], env: env, stderr_to_stdout: true)

    assert %{"readonly_scope" => "platform", "readonly_condition" => "Product is pfSense"} =
             out |> Jason.decode!() |> Enum.find(&(&1["login"] == "root"))
  end
end
