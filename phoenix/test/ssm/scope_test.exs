defmodule Ssm.ScopeTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Customers, Groups, Hosts, Scope}

  setup do
    {:ok, _} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Customers.create_customer(%{slug: "beta", name: "Beta"})
    {:ok, _} = Groups.create_group(%{slug: "web", name: "Web"})
    {:ok, _} = Groups.create_group(%{slug: "db", name: "DB"})

    hosts = %{
      acme_web: member(host_fixture(), "acme", ["web"]),
      acme_db: member(host_fixture(), "acme", ["db"]),
      acme_both: member(host_fixture(), "acme", ["web", "db"]),
      acme_none: member(host_fixture(), "acme", []),
      beta_web: member(host_fixture(), "beta", ["web"]),
      bare: host_fixture(),
      nocust_web: member(host_fixture(), nil, ["web"])
    }

    %{hosts: hosts}
  end

  defp member(host, customer, groups) do
    {:ok, host} = Hosts.update_membership(host, %{customer: customer, groups: groups})
    host
  end

  defp visible(scope, hosts) do
    ids = scope |> Scope.hosts() |> Repo.all() |> MapSet.new(& &1.id)
    for {name, host} <- hosts, MapSet.member?(ids, host.id), into: MapSet.new(), do: name
  end

  test "global sees every host, including hosts without customer or group", %{hosts: h} do
    assert visible(Scope.global(), h) == MapSet.new(Map.keys(h))
    assert Scope.global?(Scope.global())
  end

  test "none sees nothing", %{hosts: h} do
    assert visible(Scope.none(), h) == MapSet.new()
    refute Scope.global?(Scope.none())
  end

  test "customers AND groups", %{hosts: h} do
    assert visible(Scope.new(["acme"], ["web"]), h) == MapSet.new([:acme_web, :acme_both])
  end

  test "customers only: hosts without group are in scope with groups *", %{hosts: h} do
    assert visible(Scope.new(["acme"], ["*"]), h) ==
             MapSet.new([:acme_web, :acme_db, :acme_both, :acme_none])
  end

  test "groups only: hosts without customer are in scope with customers *", %{hosts: h} do
    assert visible(Scope.new(["*"], ["web"]), h) ==
             MapSet.new([:acme_web, :acme_both, :beta_web, :nocust_web])
  end

  test "several slugs per dimension", %{hosts: h} do
    assert visible(Scope.new(["acme", "beta"], ["web"]), h) ==
             MapSet.new([:acme_web, :acme_both, :beta_web])
  end

  test "unreadable stored values fail closed", %{hosts: h} do
    for {c, g} <- [
          {nil, ["*"]},
          {["*"], "web"},
          {["*", "acme"], ["*"]},
          {[1], ["*"]},
          {[], ["*"]}
        ] do
      assert visible(Scope.new(c, g), h) == MapSet.new()
    end
  end

  test "of/1 reads the user's scope; without one it is none" do
    scope = Scope.new(["acme"], ["*"])
    assert Scope.of(%{scope: scope}) == scope
    assert Scope.of(%{role: "admin"}) == Scope.none()
    assert Scope.of(nil) == Scope.none()
  end

  test "fetch_host/2 and in_scope?/2 treat out-of-scope like missing", %{hosts: h} do
    scope = Scope.new(["acme"], ["web"])
    assert {:ok, %{id: id}} = Scope.fetch_host(scope, h.acme_web.id)
    assert id == h.acme_web.id
    assert {:error, :not_found} = Scope.fetch_host(scope, h.beta_web.id)
    assert {:error, :not_found} = Scope.fetch_host(scope, -1)
    assert {:error, :not_found} = Scope.fetch_host(scope, "1")
    assert Scope.in_scope?(scope, h.acme_both.id)
    refute Scope.in_scope?(scope, h.bare.id)
    refute Scope.in_scope?(scope, nil)
  end

  test "all_in_scope?/2", %{hosts: h} do
    scope = Scope.new(["acme"], ["*"])
    assert Scope.all_in_scope?(scope, [])
    assert Scope.all_in_scope?(scope, [h.acme_web.id, h.acme_db.id, h.acme_web.id])
    refute Scope.all_in_scope?(scope, [h.acme_web.id, h.beta_web.id])
    refute Scope.all_in_scope?(scope, [h.acme_web.id, -5])
  end

  test "filter/3 restricts any host-bearing query", %{hosts: h} do
    user = user_fixture()
    authorization_fixture(user, h.acme_web)
    authorization_fixture(user, h.beta_web)

    rows =
      Ssm.Authorizations.Authorization
      |> Scope.filter(Scope.new(["acme"], ["*"]))
      |> Repo.all()

    assert Enum.map(rows, & &1.host_id) == [h.acme_web.id]
  end
end
