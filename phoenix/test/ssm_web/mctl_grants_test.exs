defmodule SsmWeb.MctlGrantsTest do
  @moduledoc """
  ADR-0012 §5/§10: contract writes that change a host's customer or groups
  (create, update, merge) reconcile grant rows in the same transaction and
  audit them with the contract actor.
  """
  use Ssm.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Ssm.Fixtures

  alias MctlContract.Principal
  alias Ssm.Activity.ActivityLog
  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs.Revocations
  alias Ssm.{Customers, Grants, Repo, Scope}
  alias SsmWeb.MctlProvider

  @p %Principal{id: 1, name: "mission-control", prefix: "ssm_abc", scopes: ~w(read setup)}

  setup do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Customers.create_customer(%{slug: "beta", name: "Beta"})
    alice = user_fixture(%{username: "alice"})

    {:ok, grant} =
      Grants.create_grant(%{role: "admin", scope: Scope.global(), actor: "admin"}, %{
        ssh_user_id: alice.id,
        customer_id: acme.id,
        login: "deploy"
      })

    %{grant: grant}
  end

  defp grant_rows(host_id),
    do: Repo.all(from a in Authorization, where: a.host_id == ^host_id, select: a.grant_id)

  test "update_host moving a host out of the customer removes the grant rows", %{grant: grant} do
    host = host_fixture()

    assert {:ok, _} =
             MctlProvider.update_host(@p, to_string(host.id), %{"customer" => "acme"})

    assert grant_rows(host.id) == [grant.id]

    assert {:ok, _} =
             MctlProvider.update_host(@p, to_string(host.id), %{"customer" => "beta"})

    assert grant_rows(host.id) == []
    assert Revocations.pending?(host.id)

    [entry] = Repo.all(from l in ActivityLog, where: l.action == "grant_remove")
    assert entry.actor_username == "mctl:mission-control"
    assert %{"trigger" => "host_membership", "grant_id" => id} = Jason.decode!(entry.meta)
    assert id == grant.id
  end

  test "merge_customer reconciles the moved hosts", %{grant: grant} do
    host = host_fixture()
    {:ok, _} = MctlProvider.update_host(@p, to_string(host.id), %{"customer" => "beta"})
    assert grant_rows(host.id) == []

    assert {:ok, %{moved_hosts: 1}} = MctlProvider.merge_customer(@p, "beta", "acme")
    assert grant_rows(host.id) == [grant.id]
  end
end
