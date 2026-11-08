defmodule Ssm.Diffs.WriteRefusalsTest do
  @moduledoc """
  Per-login write refusals of `script.sh` that a sync turns into a readable
  skip reason: a login without a usable home (missing or a symlink).
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp stub_host(host, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})
    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp grant(host, login, base64) do
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: base64, name: "laptop"})
    authorization_fixture(user, host, %{login: login})
  end

  defp refuse(host, command, kind) do
    MockClient.set_exec(host.id, command, %Result{
      stdout: "Keyfile is unsafe (#{kind}), aborting.",
      exit_code: 1
    })
  end

  test "a login without a usable home is skipped with that reason, the others are written" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "aaa", "HOME1")
    grant(host, "zzz", "HOME2")
    stub_host(host, [])
    refuse(host, "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin", "home")

    assert {{:error, {:ssh_readonly, message}}, report} =
             Diffs.sync_host_reported(MockClient, host.id)

    assert [{"aaa", "no usable home (missing or a symlink)"}] = report.skipped
    assert message =~ "no usable home"
    assert Enum.map(report.written, & &1.login) == ["zzz"]
  end

  test "a login sharing the SSH user's home is skipped: never managed" do
    host = host_fixture(%{username: "root"})
    grant(host, "root", "ROOT1")
    grant(host, "toor", "TOOR1")
    stub_host(host, [])
    refuse(host, "sh .ssm/script.sh set_authorized_keyfile toor root", "shared_home")

    assert {{:error, {:ssh_readonly, message}}, report} =
             Diffs.sync_host_reported(MockClient, host.id)

    assert [{"toor", "not managed: shares the SSH user's home (ssm's own key)"}] =
             report.skipped

    assert message =~ "shares the SSH user's home"
    assert Enum.map(report.written, & &1.login) == ["root"]
  end
end
