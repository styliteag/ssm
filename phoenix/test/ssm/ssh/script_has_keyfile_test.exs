defmodule Ssm.Ssh.ScriptHasKeyfileTest do
  @moduledoc """
  `script.sh has_keyfile <login>`: "yes" when anything sits at the login's
  `~/.ssh/authorized_keys` (a link too, dangling or not) or `~/.ssh` is a
  link; "no" when there is no such entry; "unknown" (exit 1) when getent
  does not know the login or its home does not exist.
  """

  use ExUnit.Case, async: true

  import Ssm.FakeScriptHost

  setup do
    setup!()
  end

  defp answer(ctx, login) do
    {out, 0} = run(ctx, ["has_keyfile", login])
    String.trim(out)
  end

  test "a plain file is yes, an empty ~/.ssh or no ~/.ssh is no", ctx do
    with_file = add_user(ctx, "alice")
    File.mkdir_p!(Path.join(with_file, ".ssh"))
    File.write!(Path.join(with_file, ".ssh/authorized_keys"), "")
    File.mkdir_p!(Path.join(add_user(ctx, "bob"), ".ssh"))
    add_user(ctx, "carol")

    assert answer(ctx, "alice") == "yes"
    assert answer(ctx, "bob") == "no"
    assert answer(ctx, "carol") == "no"
  end

  test "links count as present: a dangling authorized_keys, a linked ~/.ssh", ctx do
    ssh = Path.join(add_user(ctx, "dangle"), ".ssh")
    File.mkdir_p!(ssh)
    File.ln_s!(Path.join(ctx.dir, "nowhere"), Path.join(ssh, "authorized_keys"))
    File.ln_s!(Path.join(ctx.dir, "nowhere"), Path.join(add_user(ctx, "dirlink"), ".ssh"))

    assert answer(ctx, "dangle") == "yes"
    assert answer(ctx, "dirlink") == "yes"
  end

  test "an unknown login or a missing home cannot be told: unknown, exit 1", ctx do
    passwd_entry(ctx, "homeless", 1000, 1000, Path.join(ctx.dir, "gone"))

    # an LDAP outage or an unmounted home must not look like "no file"
    for login <- ["nobody-here", "homeless"] do
      assert {out, 1} = run(ctx, ["has_keyfile", login])
      assert String.trim(out) == "unknown"
    end
  end
end
