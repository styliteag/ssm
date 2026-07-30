defmodule Ssm.HostsTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Hosts

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
      b = host_fixture(%{name: "b"})

      names = a |> Hosts.jump_candidates() |> Enum.map(& &1.name)
      assert "b" in names
      refute "a" in names
    end
  end
end
