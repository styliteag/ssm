defmodule Ssm.Ssh.ScriptAtLoginTest do
  @moduledoc """
  The real `script.sh` under `sh` with an SSSD/AD login `user@domain`: getent
  and the `/etc/passwd` fallback (busybox) resolve exactly that login, its
  own home is written, read back and listed, and a near miss (`jane@corp`
  for `jane@corp.example`, `jane` alone) never reaches its file.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  @login "jane.doe@ad.corp.example"
  @tools ~w(sh cat cut grep awk find ls mv rm od tr mkdir chown head timeout sha256sum uname)

  setup do
    ctx = setup!()
    home = add_user(ctx, @login, 1001, 1001)
    Map.put(ctx, :home, home)
  end

  defp keys(ctx), do: Path.join(ctx.home, ".ssh/authorized_keys")

  test "getent: written in its own home, then has_keyfile and the listing see it", ctx do
    assert {_, 0} = write(ctx, [@login, "root"], "ssh-ed25519 JANE x\n")
    assert File.read!(keys(ctx)) =~ "ssh-ed25519 JANE x"

    assert {"yes\n", 0} = run(ctx, ["has_keyfile", @login])
    assert {out, 0} = run(ctx, ["get_ssh_keyfiles"])
    entry = out |> Jason.decode!() |> Enum.find(&(&1["login"] == @login))
    assert entry["keyfile"] =~ "ssh-ed25519 JANE x"
    assert entry["unsafe"] == ""
  end

  test "getent: near misses are unknown and never written", ctx do
    for login <- ["jane.doe@ad.corp", "jane.doe", "jane.doe@ad.corp.exampl"] do
      assert {"unknown\n", 1} = run(ctx, ["has_keyfile", login]), login
      assert {out, 1} = write(ctx, [login, "root"], "ssh-ed25519 ATTACKER x\n")
      assert out =~ "unsafe (home)", login
    end

    refute File.exists?(keys(ctx))
  end

  describe "without getent (/etc/passwd fallback)" do
    setup ctx do
      bin = Path.join(ctx.dir, "nogetent")
      File.mkdir_p!(bin)

      for tool <- @tools,
          path = System.find_executable(tool),
          do: File.ln_s!(path, Path.join(bin, tool))

      # the same script, reading the fake host's passwd instead of /etc/passwd
      script = Path.join(ctx.dir, "script_nogetent.sh")
      passwd = Path.join(ctx.dir, "passwd")
      File.write!(script, String.replace(File.read!(ctx.script), "/etc/passwd", passwd))

      env = [{"PATH", bin}, {"HOME", Path.join(ctx.dir, "root")}, {"TMPDIR", ctx.dir}]
      %{nogetent: %{script: script, env: env}}
    end

    defp sh(%{nogetent: ng} = ctx, args, input \\ "") do
      file = Path.join(ctx.dir, "stdin")
      File.write!(file, input)

      System.cmd(
        "/bin/sh",
        ["-c", ~s(f="$1"; shift; sh "$0" "$@" < "$f"), ng.script, file | args],
        env: ng.env,
        stderr_to_stdout: true
      )
    end

    test "the exact login resolves and is written", ctx do
      assert {"", code} =
               System.cmd("/bin/sh", ["-c", "command -v getent"], env: ctx.nogetent.env)

      assert code != 0

      assert {"no\n", 0} = sh(ctx, ["has_keyfile", @login])
      assert {_, 0} = sh(ctx, ["set_authorized_keyfile", @login, "root"], "ssh-ed25519 JANE x\n")
      assert File.read!(keys(ctx)) =~ "ssh-ed25519 JANE x"
    end

    test "near misses are unknown and never written", ctx do
      for login <- ["jane.doe@ad.corp", "jane.doe", "jane.doe@ad.corp.exampl", "jane.doe@"] do
        assert {"unknown\n", 1} = sh(ctx, ["has_keyfile", login]), login

        assert {out, 1} =
                 sh(ctx, ["set_authorized_keyfile", login, "root"], "ssh-ed25519 ATTACKER x\n")

        assert out =~ "unsafe (home)", login
      end

      refute File.exists?(keys(ctx))
    end
  end
end
