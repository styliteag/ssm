defmodule Ssm.InputValidationTest do
  @moduledoc """
  Changeset-level input validation: what an operator may store in keys,
  authorizations and hosts (every path — API, LiveView, bulk — goes through
  these changesets).
  """

  use Ssm.DataCase, async: true

  import Ssm.Fixtures

  alias Ssm.{Authorizations, Hosts, Repo, Users}
  alias Ssm.Hosts.Host
  alias Ssm.Ssh.Target

  defp ed25519_material do
    blob = <<11::32, "ssh-ed25519", 32::32>> <> :binary.copy(<<7>>, 32)
    Base.encode64(blob)
  end

  describe "user keys" do
    test "the key type must be a known SSH key type" do
      user = user_fixture()

      for bad <- ["ssh-ed25519 AAAAOTHER x", "command=\"sh\" ssh-ed25519", "rsa", ""] do
        assert {:error, cs} =
                 Users.create_key(%{user_id: user.id, key_type: bad, key_base64: "AAAAKEY1"}),
               "accepted key_type #{inspect(bad)}"

        assert %{key_type: [_ | _]} = errors_on(cs)
      end
    end

    test "an edit never changes the key material" do
      user = user_fixture()
      key = key_fixture(user, %{key_type: "ssh-ed25519", key_base64: ed25519_material()})

      assert {:ok, updated} =
               Users.update_key(key, %{
                 key_type: "ssh-rsa",
                 key_base64: "AAAAB3NzaC1yc2EOTHER",
                 name: "renamed"
               })

      assert updated.name == "renamed"
      stored = Users.get_key(key.id)
      assert stored.key_type == "ssh-ed25519"
      assert stored.key_base64 == key.key_base64
    end

    test "the edit form changeset carries no key material change" do
      key = key_fixture(user_fixture())
      cs = Users.change_key(key, %{"key_type" => "ssh-rsa", "key_base64" => "AAAAOTHER"})
      refute Map.has_key?(cs.changes, :key_type)
      refute Map.has_key?(cs.changes, :key_base64)
    end

    test "name and extra comment are length-capped like the API (128 / 1024)" do
      user = user_fixture()
      base = %{user_id: user.id, key_type: "ssh-ed25519", key_base64: "AAAAKEYLEN"}

      assert {:error, cs} = Users.create_key(Map.put(base, :name, String.duplicate("n", 129)))
      assert %{name: [_ | _]} = errors_on(cs)

      assert {:error, cs} =
               Users.create_key(Map.put(base, :extra_comment, String.duplicate("c", 1025)))

      assert %{extra_comment: [_ | _]} = errors_on(cs)

      key = key_fixture(user)
      assert {:error, cs} = Users.update_key(key, %{name: String.duplicate("n", 129)})
      assert %{name: [_ | _]} = errors_on(cs)
    end
  end

  describe "authorization login" do
    setup do
      %{user: user_fixture(), host: host_fixture()}
    end

    defp grant(c, login),
      do:
        Authorizations.create_authorization(%{
          user_id: c.user.id,
          host_id: c.host.id,
          login: login
        })

    test "refuses logins a host would resolve to another account or read as options", c do
      for bad <- ["0", "1000", "-oProxyCommand", "a b", "a\tb", "a:b", "../root", "a/b", " root"] do
        assert {:error, cs} = grant(c, bad), "accepted login #{inspect(bad)}"
        assert %{login: [_ | _]} = errors_on(cs)
      end
    end

    test "accepts directory-service logins (AD/SSSD): @, ., _, -, \\ and uppercase", c do
      for good <- [
            "deploy",
            "user@corp.example",
            "CORP\\jdoe",
            "John.Doe",
            "svc_backup-1",
            "r00t",
            "u$"
          ] do
        assert {:ok, _} = grant(c, good), "refused login #{inspect(good)}"
      end
    end

    test "an update is checked too", c do
      auth = authorization_fixture(c.user, c.host)
      assert {:error, cs} = Authorizations.update_authorization(auth, %{login: "0"})
      assert %{login: [_ | _]} = errors_on(cs)
    end
  end

  describe "host jump_via" do
    test "a host cannot jump through itself" do
      a = host_fixture()
      assert {:error, cs} = Hosts.update_host(a, %{jump_via: a.id})
      assert %{jump_via: [_ | _]} = errors_on(cs)
    end

    test "a jump chain must not loop" do
      a = host_fixture()
      b = host_fixture(%{jump_via: a.id})
      c = host_fixture(%{jump_via: b.id})

      assert {:error, cs} = Hosts.update_host(a, %{jump_via: c.id})
      assert %{jump_via: [_ | _]} = errors_on(cs)
      assert Repo.get!(Host, a.id).jump_via == nil
    end

    test "a valid chain is accepted" do
      a = host_fixture()
      b = host_fixture(%{jump_via: a.id})
      c = host_fixture()
      assert {:ok, %Host{jump_via: jump}} = Hosts.update_host(c, %{jump_via: b.id})
      assert jump == b.id
    end

    test "Target.from_host terminates on a looping chain already in the DB" do
      a = host_fixture()
      b = host_fixture(%{jump_via: a.id})
      {1, _} = Repo.update_all(from(h in Host, where: h.id == ^a.id), set: [jump_via: b.id])

      target = Hosts.target_for(Repo.get!(Host, a.id))
      assert %Target{host_id: id, jump_target: %Target{host_id: jump_id}} = target
      assert {id, jump_id} == {a.id, b.id}
      assert depth(target) == 2
    end

    test "Target.from_host caps a very long chain" do
      hosts = Enum.map(1..40, fn _ -> host_fixture() end)

      hosts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [h, next] ->
        Repo.update_all(from(x in Host, where: x.id == ^h.id), set: [jump_via: next.id])
      end)

      # the target plus at most max_hops jump hosts
      assert depth(Hosts.target_for(Repo.get!(Host, hd(hosts).id))) == Target.max_hops() + 1
    end

    defp depth(nil), do: 0
    defp depth(%Target{jump_target: jump}), do: 1 + depth(jump)
  end

  describe "host comment" do
    test "refuses control characters and more than 1024 characters" do
      host = host_fixture()
      assert {:error, cs} = Hosts.update_host(host, %{comment: "a\nb"})
      assert %{comment: [_ | _]} = errors_on(cs)

      assert {:error, cs} = Hosts.update_host(host, %{comment: String.duplicate("x", 1025)})
      assert %{comment: [_ | _]} = errors_on(cs)

      assert {:ok, _} = Hosts.update_host(host, %{comment: String.duplicate("x", 1024)})
    end
  end
end
