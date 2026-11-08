defmodule Ssm.Diffs.RevocationTest do
  @moduledoc """
  Revocation must reach the host: a login that lost its last grant (a
  managed login) is still synced and gets an empty file; keys of disabled
  ssm users are never expected.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Authorizations, Diffs, Users}
  alias Ssm.Diffs.{HostDiff, SyncCheck}
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp stub_host(host, files) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    entries =
      for {login, text, readonly} <- files do
        %{login: login, has_pragma: true, readonly_condition: readonly, keyfile: text}
      end

    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp writes(host) do
    for {id, cmd, input} <- MockClient.calls().exec_inputs,
        id == host.id,
        [_, login] <- [Regex.run(~r/set_authorized_keyfile (\S+)/, cmd)],
        into: %{},
        do: {login, input}
  end

  # a non-root host user, so ssm's own key never lands in these files
  defp plain_host, do: host_fixture(%{username: "ssm-admin"})

  describe "managed logins" do
    test "deleting the last grant of a login empties its file on the next sync" do
      host = plain_host()
      user = user_fixture()
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "REVOKE1", name: "laptop"})
      auth = authorization_fixture(user, host, %{login: "deploy"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      stub_host(host, [{"deploy", "ssh-ed25519 REVOKE1 laptop", nil}])

      assert {:ok, [%{login: "deploy", written_keys: 0}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => ""}
      assert Authorizations.managed_logins(host.id) == ["deploy"]
    end

    test "a later sync rewrites the empty file again (idempotent)" do
      host = plain_host()
      user = user_fixture()
      auth = authorization_fixture(user, host, %{login: "deploy"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      stub_host(host, [{"deploy", "", nil}])

      assert {:ok, [%{login: "deploy", written_keys: 0}]} = Diffs.sync_host(MockClient, host.id)
      assert {:ok, [%{login: "deploy", written_keys: 0}]} = Diffs.sync_host(MockClient, host.id)
      assert Authorizations.managed_logins(host.id) == ["deploy"]
    end

    test "a managed login without a file on the host is not written" do
      host = plain_host()
      user = user_fixture()
      auth = authorization_fixture(user, host, %{login: "gone"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      stub_host(host, [])

      assert {:ok, []} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{}
    end

    test "a login ssm never managed is left alone" do
      host = plain_host()
      stub_host(host, [{"handmade", "ssh-ed25519 HANDKEY x", nil}])

      assert {:ok, []} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{}
    end

    test "a readonly sentinel still blocks the empty write" do
      host = plain_host()
      user = user_fixture()
      auth = authorization_fixture(user, host, %{login: "deploy"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      stub_host(host, [{"deploy", "ssh-ed25519 REVOKE2 x", "Global override exists"}])

      MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy", %Result{
        stdout: "Keyfile is readonly, aborting.",
        exit_code: 1
      })

      assert {:error, {:ssh_readonly, _}} = Diffs.sync_host(MockClient, host.id)
    end

    test "a disabled host is untouched" do
      host = plain_host()
      user = user_fixture()
      auth = authorization_fixture(user, host, %{login: "deploy"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      {:ok, host} = Ssm.Hosts.update_host(host, %{disabled: true})

      assert {:error, {:host_disabled, _}} = Diffs.sync_host(MockClient, host.id)
      assert MockClient.calls().exec == []
    end

    test "host_diff and the periodic check report the leftover keys as drift" do
      host = plain_host()
      user = user_fixture()
      auth = authorization_fixture(user, host, %{login: "deploy"})
      {:ok, _} = Authorizations.delete_authorization(auth)
      stub_host(host, [{"deploy", "ssh-ed25519 REVOKE3 laptop", nil}])

      assert {:ok, %HostDiff{logins: [login]} = diff} = Diffs.host_diff(MockClient, host.id)
      assert login.login == "deploy"
      assert Enum.map(login.items, & &1.status) == [:extra_on_host]
      assert SyncCheck.status(diff) == {:needs_sync, 0, 1}
      assert SyncCheck.result(diff, %{}).state == "drift"
    end
  end

  describe "disabled ssm users" do
    test "their keys are removed by a sync, other users' keys stay" do
      host = plain_host()
      alice = user_fixture()
      bob = user_fixture()
      key_fixture(alice, %{key_type: "ssh-ed25519", key_base64: "ALICE1", name: "alice"})
      key_fixture(bob, %{key_type: "ssh-ed25519", key_base64: "BOB1", name: "bob"})
      authorization_fixture(alice, host, %{login: "deploy"})
      authorization_fixture(bob, host, %{login: "deploy"})
      {:ok, _} = Users.update_user(bob, %{enabled: false})
      stub_host(host, [{"deploy", "ssh-ed25519 ALICE1 alice\nssh-ed25519 BOB1 bob", nil}])

      assert {:ok, [%{login: "deploy", written_keys: 1}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => "ssh-ed25519 ALICE1 alice\n"}
    end

    test "their keys on the host show as drift" do
      host = plain_host()
      bob = user_fixture()
      key_fixture(bob, %{key_type: "ssh-ed25519", key_base64: "BOB2", name: "bob"})
      authorization_fixture(bob, host, %{login: "deploy"})
      {:ok, _} = Users.update_user(bob, %{enabled: false})
      stub_host(host, [{"deploy", "ssh-ed25519 BOB2 bob", nil}])

      assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert [%{status: :extra_on_host, line: "ssh-ed25519 BOB2 bob"}] = login.items
    end
  end
end
