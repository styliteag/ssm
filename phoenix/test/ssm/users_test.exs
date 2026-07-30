defmodule Ssm.UsersTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Users

  describe "users" do
    test "create/update/delete and unique username" do
      {:ok, user} = Users.create_user(%{username: "alice", comment: "ops"})
      assert user.enabled

      {:ok, updated} = Users.update_user(user, %{enabled: false})
      refute updated.enabled

      assert {:error, changeset} = Users.create_user(%{username: "alice"})
      assert %{username: [_ | _]} = errors_on(changeset)

      {:ok, _} = Users.delete_user(updated)
      assert Users.get_user(user.id) == nil
    end
  end

  describe "keys" do
    test "create key under a user and list by user" do
      user = user_fixture()
      other = user_fixture()

      {:ok, key} =
        Users.create_key(%{
          user_id: user.id,
          key_type: "ssh-ed25519",
          key_base64: "AAAAC3NzaC1lZDI1NTE5",
          name: "laptop"
        })

      assert key.name == "laptop"
      assert Users.list_keys(user_id: user.id) |> Enum.map(& &1.id) == [key.id]
      assert Users.list_keys(user_id: other.id) == []
    end

    test "key_base64 is globally unique" do
      u1 = user_fixture()
      u2 = user_fixture()
      _ = key_fixture(u1, %{key_base64: "SAMEKEYMATERIAL"})

      assert {:error, changeset} =
               Users.create_key(%{
                 user_id: u2.id,
                 key_type: "ssh-ed25519",
                 key_base64: "SAMEKEYMATERIAL"
               })

      assert %{key_base64: [_ | _]} = errors_on(changeset)
    end

    test "rejects key material that still carries a type prefix" do
      user = user_fixture()

      assert {:error, changeset} =
               Users.create_key(%{
                 user_id: user.id,
                 key_type: "ssh-ed25519",
                 key_base64: "ssh-ed25519 AAAA laptop"
               })

      assert %{key_base64: [_ | _]} = errors_on(changeset)
    end

    test "update only touches name/extra_comment" do
      user = user_fixture()
      key = key_fixture(user)

      {:ok, updated} = Users.update_key(key, %{name: "renamed", extra_comment: "note"})
      assert updated.name == "renamed"
      assert updated.extra_comment == "note"
      assert updated.key_base64 == key.key_base64
    end
  end
end
