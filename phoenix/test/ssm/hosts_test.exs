defmodule Ssm.HostsTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Hosts

  describe "limited login" do
    test "only root sees every user's authorized_keys; other logins are limited" do
      root = host_fixture(%{name: "r", username: "root"})
      deploy = host_fixture(%{name: "d", username: "deploy"})

      refute Hosts.limited?(root)
      assert Hosts.limited_reason(root) == nil
      assert Hosts.limited?(deploy)
      assert Hosts.limited_reason(deploy) =~ "deploy"
      assert Hosts.limited_reason(deploy) =~ "root"
    end
  end

  describe "CRUD" do
    test "create/get/list/update/delete round-trip" do
      {:ok, host} =
        Hosts.create_host(%{name: "web1", username: "root", address: "10.0.0.1", port: 22})

      assert Hosts.get_host(host.id).name == "web1"
      assert host in Hosts.list_hosts()

      {:ok, updated} = Hosts.update_host(host, %{comment: "edge box", disabled: true})
      assert updated.disabled
      assert updated.comment == "edge box"

      {:ok, _} = Hosts.delete_host(updated)
      assert Hosts.get_host(host.id) == nil
    end

    test "name must be unique" do
      _ = host_fixture(%{name: "dup"})

      assert {:error, changeset} =
               Hosts.create_host(%{name: "dup", username: "root", address: "9.9.9.9", port: 22})

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "address+port must be unique together" do
      _ = host_fixture(%{name: "a", address: "1.2.3.4", port: 22})

      assert {:error, changeset} =
               Hosts.create_host(%{name: "b", username: "root", address: "1.2.3.4", port: 22})

      assert errors_on(changeset)[:address] != nil
    end

    test "rejects an out-of-range port" do
      assert {:error, changeset} =
               Hosts.create_host(%{name: "x", username: "root", address: "1.1.1.1", port: 70_000})

      assert %{port: [_ | _]} = errors_on(changeset)
    end
  end

  describe "counts" do
    test "count_hosts/0 and count_disabled_hosts/0" do
      assert Hosts.count_hosts() == 0
      assert Hosts.count_disabled_hosts() == 0

      _ = host_fixture()
      disabled = host_fixture()
      {:ok, _} = Hosts.update_host(disabled, %{disabled: true})

      assert Hosts.count_hosts() == 2
      assert Hosts.count_disabled_hosts() == 1
    end
  end

  describe "jump chains" do
    test "target_for resolves a two-level jump chain" do
      bastion = host_fixture(%{name: "bastion", address: "1.1.1.1"})
      mid = host_fixture(%{name: "mid", address: "2.2.2.2", jump_via: bastion.id})
      leaf = host_fixture(%{name: "leaf", address: "3.3.3.3", jump_via: mid.id})

      target = Hosts.target_for(leaf)

      assert target.name == "leaf"
      assert target.jump_target.name == "mid"
      assert target.jump_target.jump_target.name == "bastion"
      assert target.jump_target.jump_target.jump_target == nil
    end

    test "target_for on a direct host has no jump target" do
      host = host_fixture()
      assert Hosts.target_for(host).jump_target == nil
    end

    test "jump_candidates excludes the host itself" do
      a = host_fixture(%{name: "a"})
      _b = host_fixture(%{name: "b"})

      names = Ssm.Scope.global() |> Hosts.jump_candidates(a) |> Enum.map(& &1.name)
      assert "b" in names
      refute "a" in names
    end
  end

  describe "delete_host/2 (web UI, ADR-0012)" do
    test "checks for jump dependents and deletes in one step" do
      scope = Ssm.Scope.global()
      jump = host_fixture(%{name: "jump"})
      # struct read before the dependent appears: the check must use the DB
      stale = Hosts.get_host(jump.id)
      dependent = host_fixture(%{name: "behind", jump_via: jump.id})

      assert {:error, {:jump_host_in_use, ["behind"]}} = Hosts.delete_host(scope, stale)
      assert Hosts.get_host(jump.id)
      assert Hosts.get_host(dependent.id)

      {:ok, _} = Hosts.delete_host(scope, dependent)
      assert {:ok, %{id: id}} = Hosts.delete_host(scope, stale)
      assert id == jump.id
      refute Hosts.get_host(jump.id)
    end

    test "an out-of-scope host is not found" do
      host = host_fixture()
      assert {:error, :not_found} = Hosts.delete_host(Ssm.Scope.none(), host)
      assert Hosts.get_host(host.id)
    end
  end

  test "a host needs an SSH user (the alias check in script.sh depends on it)" do
    assert {:error, changeset} =
             Ssm.Hosts.create_host(%{name: "nouser", address: "10.9.9.9", port: 22, username: ""})

    assert %{username: [_ | _]} = errors_on(changeset)
  end
end
