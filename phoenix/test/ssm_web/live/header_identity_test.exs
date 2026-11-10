defmodule SsmWeb.HeaderIdentityTest do
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest

  # ADR-0014 §3: the header names who is signed in and with which role,
  # without opening a menu, for every role (a viewer included).
  for role <- ~w(admin operator viewer) do
    test "the header shows e-mail and role of a #{role}", %{conn: conn, provider: p} do
      {:ok, lv, _} = live(sso_login(conn, p, %{"orbit_role" => unquote(role)}), ~p"/dashboard")

      assert has_element?(lv, "#current-user", "sub-1@example.test")
      assert lv |> element("#current-role") |> render() =~ unquote(role)
    end
  end

  test "a scoped user sees its customers in the header", %{conn: conn, provider: p} do
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})

    claims = %{"orbit_role" => "operator", "orbit_customers" => ["acme"]}
    {:ok, lv, _} = live(sso_login(conn, p, claims), ~p"/dashboard")

    assert has_element?(lv, "#current-user", "customers acme")
  end
end
