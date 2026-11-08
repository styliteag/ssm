defmodule Ssm.Users.KeyAssignmentTest do
  use Ssm.DataCase, async: true

  import Ssm.Fixtures

  alias Ssm.Users.KeyAssignment

  describe "suggest_username/1" do
    test "takes the part before @ of the last token" do
      assert KeyAssignment.suggest_username("Oliver Tegeler ot@FW13-OT") == "ot"
      assert KeyAssignment.suggest_username("stray@box") == "stray"
    end

    test "without @ the whole comment, slugged" do
      assert KeyAssignment.suggest_username("Oliver Tegeler") == "oliver-tegeler"
      assert KeyAssignment.suggest_username("  Laptop (work)  ") == "laptop-work"
    end

    test "no comment gives an empty name" do
      assert KeyAssignment.suggest_username(nil) == ""
      assert KeyAssignment.suggest_username("   ") == ""
      assert KeyAssignment.suggest_username("@box") == ""
    end
  end

  defp valid_material(payload), do: Base.encode64(<<11::32, "ssh-ed25519", payload::binary>>)

  defp parsed(material, name \\ "ot@FW13-OT"),
    do: %{key_type: "ssh-ed25519", key_base64: material, name: name}

  describe "assign/1" do
    test "creates the user, the key with its name and the grant in one go" do
      host = host_fixture(%{name: "web1"})

      assert {:ok, %{user: user, key: key, granted?: true}} =
               KeyAssignment.assign(%{
                 user: :new,
                 username: "ot",
                 key_name: "Oliver laptop",
                 parsed: parsed(valid_material(<<7>>)),
                 host_id: host.id,
                 login: "deploy"
               })

      assert user.username == "ot"
      assert key.user_id == user.id
      assert key.name == "Oliver laptop"
      assert Ssm.Authorizations.exists?(user.id, host.id, "deploy")
    end

    test "a taken name fails and leaves nothing behind" do
      user_fixture(%{username: "ot"})
      host = host_fixture(%{name: "web1"})
      material = valid_material(<<8>>)

      assert {:error, {:username, message}} =
               KeyAssignment.assign(%{
                 user: :new,
                 username: "ot",
                 key_name: "x",
                 parsed: parsed(material),
                 host_id: host.id,
                 login: "deploy"
               })

      assert message =~ "already been taken"
      assert Ssm.Users.get_key_by_base64(material) == nil
    end

    test "an empty name is refused" do
      host = host_fixture(%{name: "web1"})

      assert {:error, {:username, _}} =
               KeyAssignment.assign(%{
                 user: :new,
                 username: "  ",
                 key_name: "x",
                 parsed: parsed(valid_material(<<9>>)),
                 host_id: host.id,
                 login: "deploy"
               })
    end

    test "an existing user gets the key under the chosen name" do
      adopter = user_fixture(%{username: "adopter"})
      host = host_fixture(%{name: "web1"})
      material = valid_material(<<10>>)

      assert {:ok, %{user: user, key: key}} =
               KeyAssignment.assign(%{
                 user: adopter,
                 username: nil,
                 key_name: "build server",
                 parsed: parsed(material),
                 host_id: host.id,
                 login: "deploy"
               })

      assert user.id == adopter.id
      assert key.name == "build server"
      assert Ssm.Authorizations.exists?(adopter.id, host.id, "deploy")
    end
  end
end
