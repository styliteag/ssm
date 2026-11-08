defmodule Ssm.Ssh.ScriptNoGetentTest do
  @moduledoc """
  The real `script.sh` under `sh` on a host without `getent` (busybox): the
  `/etc/passwd` fallback must match the login exactly — `roo.` is not
  `root` (a regex would match it and hand out root's home).
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  @tools ~w(sh cat cut grep awk find ls mv rm od tr mkdir chown head timeout sha256sum uname)

  setup do
    ctx = setup!()
    bin = Path.join(ctx.dir, "nogetent")
    File.mkdir_p!(bin)

    for tool <- @tools,
        path = System.find_executable(tool),
        do: File.ln_s!(path, Path.join(bin, tool))

    Map.put(ctx, :env, [{"PATH", bin}, {"HOME", Path.join(ctx.dir, "root")}, {"TMPDIR", ctx.dir}])
  end

  defp sh(ctx, args, input \\ "") do
    file = Path.join(ctx.dir, "stdin")
    File.write!(file, input)

    System.cmd("/bin/sh", ["-c", ~s(f="$1"; shift; sh "$0" "$@" < "$f"), ctx.script, file | args],
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  test "the fallback is really in use (no getent on PATH)", ctx do
    assert {"", code} = System.cmd("/bin/sh", ["-c", "command -v getent"], env: ctx.env)
    assert code != 0
  end

  test "roo. is unknown, root resolves", ctx do
    assert {out, 1} = sh(ctx, ["has_keyfile", "roo."])
    assert String.trim(out) == "unknown"
    assert {_, 0} = sh(ctx, ["has_keyfile", "root"])
  end

  test "a write for roo. never reaches root's authorized_keys", ctx do
    keys = "/root/.ssh/authorized_keys"
    before = File.read(keys)

    assert {out, 1} = sh(ctx, ["set_authorized_keyfile", "roo."], "ssh-ed25519 ATTACKER x\n")
    assert out =~ "unsafe (home)"
    assert File.read(keys) == before
  end
end
