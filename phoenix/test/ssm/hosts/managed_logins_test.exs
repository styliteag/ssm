defmodule Ssm.Hosts.ManagedLoginsTest do
  @moduledoc """
  Pruning `managed_logins`: a managed login is forgotten only when it has no
  authorization and the host has no `authorized_keys` for it (asked fresh
  through `script.sh has_keyfile`). Disabled hosts are never contacted.
  Every forget attempt is audited.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Activity, Authorizations}
  alias Ssm.Hosts.ManagedLogins
  alias Ssm.Ssh.{MockClient, Result}

  setup do
    start_supervised!(MockClient)
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_default_exec(%Result{stdout: payload})
    :ok
  end

  defp has_keyfile(host, login, answer, exit_code \\ 0) do
    MockClient.set_exec(host.id, "sh .ssm/script.sh has_keyfile #{login}", %Result{
      stdout: answer <> "\n",
      exit_code: exit_code
    })
  end

  defp revoked(host, login) do
    auth = authorization_fixture(user_fixture(), host, %{login: login})
    {:ok, _} = Authorizations.delete_authorization(auth)
  end

  test "lists the managed logins of a host with their authorization count" do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    revoked(host, "old")
    other = host_fixture()
    revoked(other, "elsewhere")

    assert ManagedLogins.list(host.id) == [
             %{login: "deploy", authorizations: 2},
             %{login: "old", authorizations: 0}
           ]
  end

  test "forgets a login without authorizations and without a file on the host" do
    host = host_fixture(%{name: "web1"})
    revoked(host, "old")
    has_keyfile(host, "old", "no")

    assert {:ok, "old"} = ManagedLogins.forget(MockClient, host, "old", "admin")
    assert Authorizations.managed_logins(host.id) == []

    audit = hd(Activity.list())
    assert {audit.activity_type, audit.action, audit.target} == {"host", "forget_login", "web1"}
    assert audit.host_id == host.id
    assert Activity.details(audit)["login"] == "old"
  end

  test "refuses a login that still has authorizations, before any SSH" do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})

    assert {:error, {:conflict, message}} =
             ManagedLogins.forget(MockClient, host, "deploy", "admin")

    assert message =~ "1 authorization"
    assert MockClient.calls().exec == []
    assert Authorizations.managed_logins(host.id) == ["deploy"]
    assert hd(Activity.list()).action == "forget_login_failed"
  end

  test "refuses a login whose file is still on the host" do
    host = host_fixture()
    revoked(host, "old")
    has_keyfile(host, "old", "yes")

    assert {:error, {:conflict, message}} = ManagedLogins.forget(MockClient, host, "old", "a")
    assert message =~ "authorized_keys"
    assert Authorizations.managed_logins(host.id) == ["old"]
  end

  test "an unreadable answer or a failed SSH keeps the login" do
    host = host_fixture()
    revoked(host, "old")
    has_keyfile(host, "old", "maybe")

    assert {:error, {:ssh_connect_failed, _}} = ManagedLogins.forget(MockClient, host, "old", "a")

    has_keyfile(host, "old", "unknown", 1)
    assert {:error, {:ssh_connect_failed, _}} = ManagedLogins.forget(MockClient, host, "old", "a")
    assert Authorizations.managed_logins(host.id) == ["old"]
  end

  test "a disabled host is refused before any SSH" do
    host = host_fixture(%{disabled: true})
    revoked(host, "old")

    assert {:error, {:host_disabled, _}} = ManagedLogins.forget(MockClient, host, "old", "a")
    assert MockClient.calls().exec == []
    assert Authorizations.managed_logins(host.id) == ["old"]
  end

  test "an unknown login is not found" do
    host = host_fixture()
    assert {:error, :managed_login_not_found} = ManagedLogins.forget(MockClient, host, "x", "a")
    assert MockClient.calls().exec == []
  end

  test "the host is asked again right before the delete" do
    host = host_fixture()
    revoked(host, "old")
    has_keyfile(host, "old", "no")

    assert {:ok, "old"} = ManagedLogins.forget(MockClient, host, "old", "admin")

    asks = Enum.count(MockClient.calls().exec, fn {_, cmd} -> cmd =~ "has_keyfile old" end)
    assert asks == 2
  end
end
