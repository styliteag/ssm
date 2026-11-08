defmodule Ssm.Diffs.StoredBadRowsTest do
  @moduledoc """
  Defence in depth: rows stored before the input validation (inserted here
  directly through the Repo) with a control character in key, comment or
  options are never written to a host; the sync reports an error.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs
  alias Ssm.Diffs.HostDiff
  alias Ssm.Repo
  alias Ssm.Ssh.{MockClient, Result}
  alias Ssm.Users.UserKey

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup do
    start_supervised!(MockClient)
    host = host_fixture(%{username: "ssm-admin"})
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})
    MockClient.set_default_exec(%Result{exit_code: 0})
    %{host: host}
  end

  defp written(host) do
    for {id, cmd, input} <- MockClient.calls().exec_inputs,
        id == host.id,
        String.contains?(cmd, "set_authorized_keyfile deploy"),
        do: input
  end

  defp raw_key(user, base64, name) do
    Repo.insert!(%UserKey{
      user_id: user.id,
      key_type: "ssh-ed25519",
      key_base64: base64,
      name: name
    })
  end

  defp raw_grant(user, host, options) do
    Repo.insert!(%Authorization{
      user_id: user.id,
      host_id: host.id,
      login: "deploy",
      options: options
    })
  end

  test "a newline in a stored key comment: the key is written without its comment", %{
    host: host
  } do
    good = user_fixture()
    key_fixture(good, %{key_type: "ssh-ed25519", key_base64: "GOODKEY", name: "ok"})
    authorization_fixture(good, host, %{login: "deploy"})
    bad = user_fixture()
    raw_key(bad, "BADNAME", "x\nssh-ed25519 AAAAINJECTED evil")
    raw_grant(bad, host, nil)

    assert {:ok, [%{written_keys: 2}]} = Diffs.sync_host(MockClient, host.id)
    assert written(host) == ["ssh-ed25519 GOODKEY ok\nssh-ed25519 BADNAME\n"]
  end

  test "control characters in the stored key material are refused", %{host: host} do
    good = user_fixture()
    key_fixture(good, %{key_type: "ssh-ed25519", key_base64: "GOODKEY2", name: "ok"})
    authorization_fixture(good, host, %{login: "deploy"})
    bad = user_fixture()
    bad_key = raw_key(bad, "BAD\nssh-ed25519 AAAAINJECTED", "x")
    raw_grant(bad, host, nil)

    assert {:error, {:invalid_key_line, message}} = Diffs.sync_host(MockClient, host.id)
    assert message =~ "key id #{bad_key.id}"
    assert written(host) == ["ssh-ed25519 GOODKEY2 ok\n"]
  end

  test "stored options with a newline are never written", %{host: host} do
    user = user_fixture()
    raw_key(user, "OPTBAD", "laptop")
    raw_grant(user, host, "no-pty\nssh-ed25519 AAAAINJECTED evil")

    assert {:ok, _} = Diffs.sync_host(MockClient, host.id)
    assert written(host) == [""]
  end

  test "the diff never shows the refused line as expected", %{host: host} do
    user = user_fixture()
    raw_key(user, "BAD\nKEY2", "x")
    raw_grant(user, host, nil)

    assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
    assert login.items == []
  end
end
