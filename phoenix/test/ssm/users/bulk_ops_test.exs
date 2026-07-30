defmodule Ssm.Users.BulkOpsTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Authorizations
  alias Ssm.Users
  alias Ssm.Users.BulkOps

  describe "split_user/3" do
    test "moves the chosen keys to a new user and copies all authorizations" do
      user = user_fixture(%{username: "alice"})
      keep = key_fixture(user)
      move_a = key_fixture(user)
      move_b = key_fixture(user)
      host = host_fixture()
      _auth = authorization_fixture(user, host, %{login: "deploy"})

      assert {:ok, result} = BulkOps.split_user(user, "alice copy", [move_a.id, move_b.id])

      assert result.new_user.username == "alice copy"
      assert result.new_user.comment == "Split from alice"
      assert result.moved_keys == 2
      assert result.copied_authorizations == 1

      assert [%{id: keep_id}] = Users.list_keys(user_id: user.id)
      assert keep_id == keep.id
      assert length(Users.list_keys(user_id: result.new_user.id)) == 2

      assert Authorizations.exists?(result.new_user.id, host.id, "deploy")
      assert Authorizations.exists?(user.id, host.id, "deploy")
    end

    test "refuses to take every key" do
      user = user_fixture()
      only = key_fixture(user)

      assert {:error, :must_keep_one_key} = BulkOps.split_user(user, "other", [only.id])
      assert Users.get_user(user.id)
      assert [_] = Users.list_keys(user_id: user.id)
    end

    test "refuses an empty selection and foreign keys" do
      user = user_fixture()
      _own = key_fixture(user)
      stranger = user_fixture()
      foreign = key_fixture(stranger)

      assert {:error, :no_keys_selected} = BulkOps.split_user(user, "other", [])
      assert {:error, :keys_not_owned} = BulkOps.split_user(user, "other", [foreign.id])
    end

    test "a taken username rolls the whole split back" do
      user = user_fixture(%{username: "alice"})
      _keep = key_fixture(user)
      move = key_fixture(user)
      _clash = user_fixture(%{username: "taken"})

      assert {:error, %Ecto.Changeset{}} = BulkOps.split_user(user, "taken", [move.id])
      assert length(Users.list_keys(user_id: user.id)) == 2
    end
  end

  describe "merge_users/2" do
    test "into an existing target: keys move, grants copy deduped, sources die" do
      target = user_fixture(%{username: "canonical"})
      source = user_fixture(%{username: "dupe"})
      _source_key = key_fixture(source)
      host_shared = host_fixture()
      host_extra = host_fixture()

      _target_auth = authorization_fixture(target, host_shared, %{login: "root"})
      _dupe_auth = authorization_fixture(source, host_shared, %{login: "root"})
      _extra_auth = authorization_fixture(source, host_extra, %{login: "deploy"})

      assert {:ok, result} = BulkOps.merge_users([source, target], target)

      assert result.target.id == target.id
      assert result.moved_keys == 1
      assert result.copied_authorizations == 1
      assert result.skipped_authorizations == 1
      assert result.deleted_users == ["dupe"]

      assert Users.get_user(source.id) == nil
      assert [_] = Users.list_keys(user_id: target.id)
      assert Authorizations.exists?(target.id, host_extra.id, "deploy")
      assert length(Authorizations.list_authorizations(user_id: target.id)) == 2
    end

    test "into a brand-new user from attrs" do
      a = user_fixture(%{username: "a"})
      b = user_fixture(%{username: "b"})
      _key = key_fixture(a)
      host = host_fixture()
      _auth = authorization_fixture(b, host, %{login: "deploy"})

      assert {:ok, result} = BulkOps.merge_users([a, b], %{username: "merged"})

      assert result.target.username == "merged"
      assert Enum.sort(result.deleted_users) == ["a", "b"]
      assert Users.get_user(a.id) == nil
      assert Users.get_user(b.id) == nil
      assert [_] = Users.list_keys(user_id: result.target.id)
      assert Authorizations.exists?(result.target.id, host.id, "deploy")
    end

    test "merging only the target itself is refused" do
      target = user_fixture()
      assert {:error, :nothing_to_merge} = BulkOps.merge_users([target], target)
      assert Users.get_user(target.id)
    end
  end

  describe "bulk_delete/1" do
    test "deletes every user and reports missing rows honestly" do
      a = user_fixture(%{username: "a"})
      b = user_fixture(%{username: "b"})
      _key = key_fixture(a)
      host = host_fixture()
      _auth = authorization_fixture(a, host)

      ghost = user_fixture(%{username: "ghost"})
      {:ok, _} = Users.delete_user(ghost)

      result = BulkOps.bulk_delete([a, b, ghost])

      assert Enum.map(result.deleted, & &1.username) == ["a", "b"]
      assert [{^ghost, :not_found}] = result.failed
      assert Users.get_user(a.id) == nil
      assert Users.list_keys(user_id: a.id) == []
      assert Authorizations.list_authorizations(user_id: a.id) == []
    end
  end

  describe "username suggestions" do
    test "split suggests the first free '<name> copy' variant" do
      assert BulkOps.suggest_split_username("alice", []) == "alice copy"
      assert BulkOps.suggest_split_username("alice", ["alice copy"]) == "alice copy2"

      assert BulkOps.suggest_split_username("alice", ["Alice Copy", "alice copy2"]) ==
               "alice copy3"
    end

    test "merge strips a trailing copy suffix and finds a free name" do
      assert BulkOps.suggest_merge_username("alice copy", ["alice copy"]) == "alice"
      assert BulkOps.suggest_merge_username("alice copy2", ["alice"]) == "alice-2"
      assert BulkOps.suggest_merge_username("bob", ["bob"]) == "bob-2"
    end
  end
end
