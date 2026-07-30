defmodule Ssm.AuthorizationsTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Authorizations

  test "create/list with preloads and unique (user,host,login)" do
    user = user_fixture()
    host = host_fixture()

    {:ok, auth} =
      Authorizations.create_authorization(%{
        user_id: user.id,
        host_id: host.id,
        login: "deploy",
        options: ~s(no-pty,from="10.0.0.0/8")
      })

    [loaded] = Authorizations.list_authorizations(host_id: host.id)
    assert loaded.id == auth.id
    assert loaded.user.username == user.username
    assert loaded.host.name == host.name

    assert {:error, changeset} =
             Authorizations.create_authorization(%{
               user_id: user.id,
               host_id: host.id,
               login: "deploy"
             })

    assert errors_on(changeset) != %{}
  end

  test "the same user may have different logins on the same host" do
    user = user_fixture()
    host = host_fixture()

    {:ok, _} =
      Authorizations.create_authorization(%{user_id: user.id, host_id: host.id, login: "deploy"})

    {:ok, _} =
      Authorizations.create_authorization(%{user_id: user.id, host_id: host.id, login: "root"})

    assert length(Authorizations.list_authorizations(host_id: host.id)) == 2
  end

  test "update and delete" do
    user = user_fixture()
    host = host_fixture()
    auth = authorization_fixture(user, host)

    {:ok, updated} = Authorizations.update_authorization(auth, %{comment: "temp access"})
    assert updated.comment == "temp access"

    {:ok, _} = Authorizations.delete_authorization(updated)
    assert Authorizations.get_authorization(auth.id) == nil
  end
end
