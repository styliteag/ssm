defmodule Ssm.Authorizations.ManagedLoginsTest do
  @moduledoc """
  Every login that ever held a grant on a host is recorded in
  `managed_logins`, so a sync can still empty its file after the last grant
  is gone.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Authorizations, Hosts}
  alias Ssm.Users.KeyAssignment

  test "creating a grant records its login once" do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    authorization_fixture(user_fixture(), host, %{login: "app"})

    assert Authorizations.managed_logins(host.id) == ["app", "deploy"]
    assert Authorizations.managed_logins(host_fixture().id) == []
  end

  test "deleting the grant keeps the login managed" do
    host = host_fixture()
    auth = authorization_fixture(user_fixture(), host, %{login: "deploy"})
    {:ok, _} = Authorizations.delete_authorization(auth)

    assert Authorizations.managed_logins(host.id) == ["deploy"]
  end

  test "a rejected grant records nothing" do
    host = host_fixture()

    assert {:error, _} =
             Authorizations.create_authorization(%{
               user_id: user_fixture().id,
               host_id: host.id,
               login: String.duplicate("x", 256)
             })

    assert Authorizations.managed_logins(host.id) == []
  end

  test "bulk_grant records the login on every host" do
    [h1, h2] = [host_fixture(), host_fixture()]
    {:ok, _} = Authorizations.bulk_grant([user_fixture().id], [h1.id, h2.id], "ops")

    assert Authorizations.managed_logins(h1.id) == ["ops"]
    assert Authorizations.managed_logins(h2.id) == ["ops"]
  end

  test "moving a grant to another login keeps both managed" do
    host = host_fixture()
    auth = authorization_fixture(user_fixture(), host, %{login: "old"})
    {:ok, _} = Authorizations.update_authorization(auth, %{login: "new"})

    assert Authorizations.managed_logins(host.id) == ["new", "old"]
  end

  test "assigning an unknown key from the diff page records the login" do
    host = host_fixture()
    user = user_fixture()

    {:ok, _} =
      KeyAssignment.assign(%{
        user: user,
        username: nil,
        key_name: "found",
        parsed: %{key_type: "ssh-ed25519", key_base64: "FOUNDKEY1", name: nil},
        host_id: host.id,
        login: "svc"
      })

    assert Authorizations.managed_logins(host.id) == ["svc"]
  end

  test "the rows follow their host (ON DELETE CASCADE)" do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    {:ok, _} = Hosts.delete_host(host)

    assert Authorizations.managed_logins(host.id) == []
  end
end
