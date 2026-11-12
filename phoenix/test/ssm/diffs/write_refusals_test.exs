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

    assert [{"toor", "not managed: shares the SSH user's home (ssm's own key)" <> _}] =
             report.skipped

    assert message =~ "shares the SSH user's home"
    assert Enum.map(report.written, & &1.login) == ["root"]
  end

  @sha String.duplicate("ab", 32)

  test "a sync names the sha256 of each listed file; a stale refusal skips that login" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "aaa", "STALE1")
    grant(host, "zzz", "STALE2")

    stub_host(host, [
      %{login: "aaa", has_pragma: true, keyfile: "", sha256: @sha},
      %{login: "zzz", has_pragma: true, keyfile: ""}
    ])

    MockClient.set_exec(
      host.id,
      "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin #{@sha}",
      %Result{stdout: "Keyfile changed since it was read (stale), aborting.", exit_code: 1}
    )

    assert {{:error, {:ssh_readonly, _}}, report} = Diffs.sync_host_reported(MockClient, host.id)
    assert [{"aaa", "changed on the host since it was read; not written"}] = report.skipped
    assert Enum.map(report.written, & &1.login) == ["zzz"]
  end

  test "an unknown SSH user is a per-login skip with a readable reason" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "aaa", "SSHU1")
    stub_host(host, [])
    refuse(host, "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin", "ssh_user")

    assert {{:error, {:ssh_readonly, _}}, report} = Diffs.sync_host_reported(MockClient, host.id)
    assert [{"aaa", "the SSH user is unknown on the host; nothing written"}] = report.skipped
  end

  test "a sync waits for the host's write lock" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "aaa", "LOCK1")
    stub_host(host, [])
    test = self()

    holder =
      spawn(fn ->
        Ssm.Hosts.WriteLock.run(host.id, fn ->
          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked
    task = Task.async(fn -> Diffs.sync_host(MockClient, host.id) end)
    assert Task.yield(task, 200) == nil
    assert MockClient.calls().exec == []

    send(holder, :release)
    assert {:ok, _} = Task.await(task)
  end

  test "a stored login a host would misread is skipped without asking the host" do
    host = host_fixture(%{username: "root"})
    grant(host, "deploy", "LEGACY1")
    legacy = grant(host, "legacy", "LEGACY2")

    {1, _} =
      Ssm.Repo.update_all(
        from(a in Ssm.Authorizations.Authorization, where: a.id == ^legacy.id),
        set: [login: "0"]
      )

    stub_host(host, [])

    assert {{:error, {:ssh_readonly, _}}, report} = Diffs.sync_host_reported(MockClient, host.id)
    assert [{"0", reason}] = report.skipped
    assert reason =~ "invalid login"
    assert Enum.map(report.written, & &1.login) == ["deploy"]

    refute Enum.any?(MockClient.calls().exec, fn {_id, cmd} ->
             cmd =~ "set_authorized_keyfile 0"
           end)
  end

  test "a login the script refuses as invalid is a per-login skip" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "aaa", "INVAL1")
    grant(host, "zzz", "INVAL2")
    stub_host(host, [])
    refuse(host, "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin", "invalid_login")

    assert {{:error, {:ssh_readonly, _}}, report} = Diffs.sync_host_reported(MockClient, host.id)
    assert [{"aaa", reason}] = report.skipped
    assert reason =~ "invalid login"
    assert Enum.map(report.written, & &1.login) == ["zzz"]
  end
end
