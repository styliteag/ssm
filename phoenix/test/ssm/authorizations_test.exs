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

  test "count_authorizations/0" do
    assert Authorizations.count_authorizations() == 0

    user = user_fixture()
    host = host_fixture()
    _ = authorization_fixture(user, host)

    assert Authorizations.count_authorizations() == 1
  end

  test "exists?/3 and get_by_grant/3 address one exact (user, host, login)" do
    user = user_fixture()
    host = host_fixture()
    auth = authorization_fixture(user, host, %{login: "deploy"})

    assert Authorizations.exists?(user.id, host.id, "deploy")
    refute Authorizations.exists?(user.id, host.id, "root")

    assert Authorizations.get_by_grant(user.id, host.id, "deploy").id == auth.id
    assert Authorizations.get_by_grant(user.id, host.id, "root") == nil
  end

  test "existing_grant_pairs/3 returns the granted subset of the cross product" do
    [u1, u2] = [user_fixture(), user_fixture()]
    [h1, h2] = [host_fixture(), host_fixture()]
    authorization_fixture(u1, h1, %{login: "root"})
    authorization_fixture(u2, h2, %{login: "root"})
    authorization_fixture(u1, h2, %{login: "deploy"})

    pairs = Authorizations.existing_grant_pairs([u1.id, u2.id], [h1.id, h2.id], "root")
    assert pairs == MapSet.new([{u1.id, h1.id}, {u2.id, h2.id}])
  end

  describe "bulk_grant/4" do
    test "grants the full cross product, skipping existing pairs" do
      [u1, u2] = [user_fixture(), user_fixture()]
      [h1, h2] = [host_fixture(), host_fixture()]
      authorization_fixture(u1, h1, %{login: "root"})

      assert {:ok, %{created: created, skipped: 1}} =
               Authorizations.bulk_grant([u1.id, u2.id], [h1.id, h2.id], "root", "no-pty")

      assert length(created) == 3
      assert Enum.all?(created, &(&1.options == "no-pty"))
      assert Authorizations.count_authorizations() == 4
    end

    test "a changeset failure aborts the batch with no rows written" do
      user = user_fixture()
      host = host_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Authorizations.bulk_grant(
                 [user.id],
                 [host.id],
                 String.duplicate("x", 256)
               )

      assert %{login: _} = errors_on(changeset)
      assert Authorizations.count_authorizations() == 0
    end
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
