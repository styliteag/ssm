defmodule Ssm.HostsMembershipTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Customers, Groups, Hosts}

  setup do
    {:ok, customer} = Customers.create_customer(%{slug: "kunde-a", name: "Kunde A"})
    {:ok, web} = Groups.create_group(%{slug: "web", name: "Web"})
    {:ok, prod} = Groups.create_group(%{slug: "prod", name: "Prod"})
    {:ok, customer: customer, web: web, prod: prod}
  end

  test "new hosts get timestamps" do
    host = host_fixture()
    assert %DateTime{} = host.inserted_at
    assert %DateTime{} = host.updated_at
  end

  test "assign customer and groups by slug, then clear them" do
    host = host_fixture()

    assert {:ok, host} =
             Hosts.update_membership(host, %{customer: "kunde-a", groups: ["web", "prod"]})

    assert host.customer.slug == "kunde-a"
    assert host.groups |> Enum.map(& &1.slug) |> Enum.sort() == ["prod", "web"]

    reloaded = Hosts.get_host_with_membership(host.id)
    assert reloaded.customer.slug == "kunde-a"
    assert length(reloaded.groups) == 2

    assert {:ok, host} = Hosts.update_membership(host, %{customer: nil, groups: []})
    assert host.customer == nil
    assert host.groups == []
  end

  test "only the given keys change" do
    host = host_fixture()
    {:ok, host} = Hosts.update_membership(host, %{customer: "kunde-a", groups: ["web"]})

    {:ok, host} = Hosts.update_membership(host, %{groups: ["prod"]})
    assert host.customer.slug == "kunde-a"
    assert Enum.map(host.groups, & &1.slug) == ["prod"]

    {:ok, host} = Hosts.update_membership(host, %{name: "renamed"})
    assert host.name == "renamed"
    assert Enum.map(host.groups, & &1.slug) == ["prod"]
  end

  test "unknown slugs are refused and nothing changes" do
    host = host_fixture()

    assert {:error, {:validation, %{"customer" => [_]}}} =
             Hosts.update_membership(host, %{customer: "ghost"})

    assert {:error, {:validation, %{"groups" => [msg]}}} =
             Hosts.update_membership(host, %{groups: ["web", "ghost"]})

    assert msg =~ "ghost"
    assert Hosts.get_host_with_membership(host.id).groups == []
  end

  test "a name conflict comes back as a changeset error" do
    _ = host_fixture(%{name: "taken"})
    host = host_fixture()
    assert {:error, %Ecto.Changeset{}} = Hosts.update_membership(host, %{name: "taken"})
  end

  test "membership changes bump updated_at" do
    host = host_fixture()
    past = ~U[2020-01-01 00:00:00Z]
    {:ok, host} = host |> Ecto.Changeset.change(updated_at: past) |> Repo.update()

    {:ok, host} = Hosts.update_membership(host, %{groups: ["web"]})
    assert DateTime.compare(host.updated_at, past) == :gt
  end

  test "deleting a host or a group removes the link rows" do
    host = host_fixture()
    {:ok, _} = Hosts.update_membership(host, %{groups: ["web"]})
    {:ok, _} = Hosts.delete_host(host)
    assert Repo.aggregate("host_groups", :count) == 0
  end

  describe "page_hosts/3" do
    test "keyset by id with filters", %{} do
      a = host_fixture(%{name: "a"})
      b = host_fixture(%{name: "b"})
      c = host_fixture(%{name: "c"})
      {:ok, _} = Hosts.update_membership(a, %{customer: "kunde-a", groups: ["web"]})
      {:ok, _} = Hosts.update_membership(c, %{customer: "kunde-a"})

      assert {[%{id: id1}, %{id: id2}], next} = Hosts.page_hosts(nil, 2, %{})
      assert [id1, id2] == [a.id, b.id]
      assert next == b.id
      assert {[%{id: id3}], nil} = Hosts.page_hosts(next, 2, %{})
      assert id3 == c.id

      assert {hosts, nil} = Hosts.page_hosts(nil, 10, %{customer: "kunde-a"})
      assert Enum.map(hosts, & &1.id) == [a.id, c.id]

      assert {[only], nil} = Hosts.page_hosts(nil, 10, %{group: "web"})
      assert only.id == a.id
      assert only.customer.slug == "kunde-a"

      assert {[], nil} = Hosts.page_hosts(nil, 10, %{customer: "ghost"})
    end

    test "changed_after filter" do
      old = host_fixture()

      {:ok, _} =
        old |> Ecto.Changeset.change(updated_at: ~U[2020-01-01 00:00:00Z]) |> Repo.update()

      new = host_fixture()

      assert {[%{id: id}], nil} =
               Hosts.page_hosts(nil, 10, %{changed_after: ~U[2021-01-01 00:00:00Z]})

      assert id == new.id
    end
  end
end
