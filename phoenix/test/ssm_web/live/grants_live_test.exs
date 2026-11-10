defmodule SsmWeb.GrantsLiveTest do
  @moduledoc """
  ADR-0012 phase 2 UI: grants per SSH user and per customer/group, grant
  rows read-only on the Authorizations page ("via customer X"), revocation
  pending on the Hosts page.
  """
  use SsmWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Authorizations.Authorization
  alias Ssm.{Customers, Grants, Groups, Hosts, Repo, Scope}

  setup [:setup_htpasswd, :log_in]

  setup do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, web} = Groups.create_group(%{slug: "web", name: "Webservers"})
    {:ok, host} = Hosts.update_membership(host_fixture(%{name: "acme-1"}), %{customer: "acme"})
    alice = user_fixture(%{username: "alice"})
    %{acme: acme, web: web, host: host, alice: alice}
  end

  defp admin_grant(ctx, login \\ "deploy") do
    {:ok, grant} =
      Grants.create_grant(%{role: "admin", scope: Scope.global(), actor: "admin"}, %{
        ssh_user_id: ctx.alice.id,
        customer_id: ctx.acme.id,
        login: login
      })

    grant
  end

  test "an empty grant list offers to create the first grant", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/grants")
    assert has_element?(view, "#no-grants button", "New grant")
  end

  test "creates a grant for an SSH user and expands it", %{conn: conn} = ctx do
    {:ok, lv, html} = live(conn, ~p"/grants?user_id=#{ctx.alice.id}")
    assert html =~ "Grants of alice"

    lv |> element("#new-grant") |> render_click()

    html =
      lv
      |> form("#grant-form",
        grant: %{
          ssh_user_id: ctx.alice.id,
          target: "customer:#{ctx.acme.id}",
          login: "deploy",
          comment: "ops"
        }
      )
      |> render_submit()

    assert html =~ "Grant for alice created."
    assert has_element?(lv, "#grants", "customer Acme")

    assert [%Authorization{login: "deploy", grant_id: grant_id}] =
             Repo.all(from a in Authorization, where: a.host_id == ^ctx.host.id)

    assert is_integer(grant_id)
  end

  test "the form says how many hosts the target reaches", %{conn: conn} = ctx do
    {:ok, _} = Hosts.update_membership(host_fixture(%{name: "acme-2"}), %{customer: "acme"})
    {:ok, lv, _html} = live(conn, ~p"/grants")
    lv |> element("#new-grant") |> render_click()

    refute has_element?(lv, "#grant-preview")

    lv
    |> form("#grant-form", grant: %{target: "customer:#{ctx.acme.id}", login: "deploy"})
    |> render_change()

    assert has_element?(lv, "#grant-preview", "2 hosts")
    assert has_element?(lv, "#grant-preview", "deploy")
  end

  test "a missing target re-renders the form with an error", %{conn: conn} = ctx do
    {:ok, lv, _} = live(conn, ~p"/grants")
    lv |> element("#new-grant") |> render_click()

    html =
      lv
      |> form("#grant-form", grant: %{ssh_user_id: ctx.alice.id, login: "deploy"})
      |> render_submit()

    assert html =~ "pick a customer or a group"
    assert Grants.list_grants(Scope.global()) == []
  end

  test "the customer view lists and deletes its grants", %{conn: conn} = ctx do
    grant = admin_grant(ctx)
    {:ok, lv, html} = live(conn, ~p"/grants?customer_id=#{ctx.acme.id}")
    assert html =~ "Grants on customer Acme"
    assert has_element?(lv, "#grants-#{grant.id}", "alice")

    {:ok, _lv, html} = live(conn, ~p"/grants?group_id=#{ctx.web.id}")
    assert html =~ "Grants on group Webservers"
    refute html =~ "grants-#{grant.id}"

    html = lv |> element("#delete-grant-#{grant.id}") |> render_click()
    assert html =~ "Grant deleted."
    assert Grants.list_grants(Scope.global()) == []
  end

  test "grant rows are read-only on the Authorizations page", %{conn: conn} = ctx do
    admin_grant(ctx)
    row = Repo.get_by!(Authorization, host_id: ctx.host.id)

    {:ok, lv, _} = live(conn, ~p"/authorizations")
    assert has_element?(lv, "#via-grant-#{row.id}", "via customer Acme")
    refute has_element?(lv, "#edit-authorization-#{row.id}")
    refute has_element?(lv, "#delete-authorization-#{row.id}")

    assert render_click(lv, "delete", %{"id" => to_string(row.id)}) =~ "read-only"
    assert render_click(lv, "edit", %{"id" => to_string(row.id)}) =~ "read-only"
    assert Repo.get(Authorization, row.id)
  end

  test "a reconcile after a manual delete is audited with the web user", %{conn: conn} = ctx do
    manual = authorization_fixture(ctx.alice, ctx.host, %{login: "deploy"})
    admin_grant(ctx)

    {:ok, lv, _} = live(conn, ~p"/authorizations")
    lv |> element("#delete-authorization-#{manual.id}") |> render_click()

    [entry] = Repo.all(from l in Ssm.Activity.ActivityLog, where: l.action == "grant_add")
    assert entry.actor_username == "admin"
    assert Jason.decode!(entry.meta)["trigger"] == "authorization_delete"
    assert Ssm.Diffs.Revocations.pending?(ctx.host.id)
  end

  test "the Users page links each user's grants", %{conn: conn} = ctx do
    admin_grant(ctx)
    {:ok, lv, _} = live(conn, ~p"/users")
    assert has_element?(lv, "#user-grants-#{ctx.alice.id}", "1")
  end

  test "the Hosts page shows revocation pending after a grant delete", %{conn: conn} = ctx do
    grant = admin_grant(ctx)
    {:ok, _} = Grants.delete_grant(%{role: "admin", scope: Scope.global(), actor: "a"}, grant)

    {:ok, lv, _} = live(conn, ~p"/hosts")
    assert has_element?(lv, "#revocation-pending-#{ctx.host.id}", "pending sync")
  end
end
