defmodule SsmWeb.GrantsScopeLiveTest do
  @moduledoc """
  ADR-0012 §5 on the Grants page: a scoped operator sees and targets only
  its scope, a viewer changes nothing.
  """
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.{Customers, Grants, Scope}

  setup do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, beta} = Customers.create_customer(%{slug: "beta", name: "Beta"})
    alice = user_fixture(%{username: "alice"})
    admin = %{role: "admin", scope: Scope.global(), actor: "admin"}

    {:ok, beta_grant} =
      Grants.create_grant(admin, %{ssh_user_id: alice.id, customer_id: beta.id, login: "b"})

    %{acme: acme, beta: beta, alice: alice, beta_grant: beta_grant}
  end

  defp scoped(conn, p, role \\ "operator"),
    do: sso_login(conn, p, %{"orbit_role" => role, "orbit_customers" => ["acme"]})

  test "a scoped operator sees only its targets and grants", %{conn: conn, provider: p} = ctx do
    {:ok, lv, html} = live(scoped(conn, p), ~p"/grants")
    assert has_element?(lv, "#target-customer-#{ctx.acme.id}")
    refute has_element?(lv, "#target-customer-#{ctx.beta.id}")
    refute html =~ "grants-#{ctx.beta_grant.id}"

    assert render_click(lv, "delete-grant", %{"id" => to_string(ctx.beta_grant.id)}) =~
             "Grant not found."

    lv |> element("#new-grant") |> render_click()

    html =
      render_submit(lv, "save", %{
        "grant" => %{
          "ssh_user_id" => ctx.alice.id,
          "target" => "customer:#{ctx.beta.id}",
          "login" => "x"
        }
      })

    assert html =~ "outside your scope"

    lv |> element("#new-grant") |> render_click()

    html =
      render_submit(lv, "save", %{
        "grant" => %{
          "ssh_user_id" => ctx.alice.id,
          "target" => "customer:#{ctx.acme.id}",
          "login" => "x"
        }
      })

    assert html =~ "Grant for alice created."
  end

  test "a viewer cannot create or delete grants", %{conn: conn, provider: p} = ctx do
    conn = sso_login(conn, p, %{"orbit_role" => "viewer"})
    {:ok, lv, _html} = live(conn, ~p"/grants")
    refute has_element?(lv, "#new-grant")

    assert render_click(lv, "delete-grant", %{"id" => to_string(ctx.beta_grant.id)}) =~
             "read-only"

    assert render_submit(lv, "save", %{
             "grant" => %{
               "ssh_user_id" => ctx.alice.id,
               "target" => "customer:#{ctx.acme.id}",
               "login" => "x"
             }
           }) =~ "read-only"

    assert length(Grants.list_grants(Scope.global())) == 1
  end
end
