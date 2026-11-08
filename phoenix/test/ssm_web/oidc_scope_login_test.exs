defmodule SsmWeb.OIDCScopeLoginTest do
  @moduledoc "ADR-0012 phase 1: scope claims at login, fail closed, refusals audited."
  use SsmWeb.OIDCCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ssm.Accounts
  alias Ssm.Accounts.Operator
  alias Ssm.Activity.ActivityLog
  alias Ssm.{Repo, Scope}

  setup do
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Ssm.Groups.create_group(%{slug: "web", name: "Web"})
    :ok
  end

  defp refused?(conn), do: redirected_to(conn) == "/sign-in"

  defp refusal_reasons do
    from(l in ActivityLog, where: l.action == "oidc.login_refused")
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.meta)["reason"])
  end

  describe "refused and audited with the reason" do
    for {role, claims, reason} <- [
          {"operator", %{"orbit_customers" => nil}, "customers_missing"},
          {"viewer", %{"orbit_customers" => nil}, "customers_missing"},
          {"operator", %{"orbit_groups" => nil}, "groups_missing"},
          {"viewer", %{"orbit_groups" => nil}, "groups_missing"},
          {"operator", %{"orbit_customers" => ["*", "acme"]}, "customers_malformed"},
          {"viewer", %{"orbit_groups" => ["*", "web"]}, "groups_malformed"},
          {"operator", %{"orbit_groups" => "web"}, "groups_malformed"},
          {"admin", %{"orbit_customers" => ["acme"]}, "admin_scoped"},
          {"admin", %{"orbit_groups" => ["web"]}, "admin_scoped"}
        ] do
      test "#{role} with #{inspect(claims)} -> #{reason}", %{conn: conn, provider: p} do
        claims = Map.put(unquote(Macro.escape(claims)), "orbit_role", unquote(role))
        conn = sso_login(conn, p, claims)

        assert refused?(conn)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Single sign-on failed"
        assert Repo.all(Operator) == []
        assert refusal_reasons() == [unquote(reason)]
      end
    end
  end

  describe "accepted" do
    test "scope is stored on the operator and overwritten at every login", %{
      conn: conn,
      provider: p
    } do
      claims = %{"orbit_role" => "operator", "orbit_customers" => ["acme"]}
      conn = sso_login(conn, p, Map.put(claims, "orbit_groups", ["web"]))
      assert redirected_to(conn) == "/dashboard"

      op = Repo.one!(Operator)
      assert Accounts.customers(op) == ["acme"]
      assert Accounts.groups(op) == ["web"]
      assert Accounts.scope(op) == Scope.new(["acme"], ["web"])

      build_conn() |> sso_login(p, Map.put(claims, "orbit_groups", ["*"]))
      op = Repo.one!(Operator)
      assert Accounts.groups(op) == ["*"]
      assert Accounts.scope(op) == %Scope{customers: ["acme"], groups: :all}
    end

    test "OIDC_GROUPS_DEFAULT=* accepts a missing groups claim as *", %{conn: conn, provider: p} do
      put_config(groups_default: :all)
      conn = sso_login(conn, p, %{"orbit_role" => "viewer", "orbit_groups" => nil})
      assert redirected_to(conn) == "/dashboard"
      assert Accounts.groups(Repo.one!(Operator)) == ["*"]
    end

    test "admin without scope claims is global", %{conn: conn, provider: p} do
      conn =
        sso_login(conn, p, %{
          "orbit_role" => "admin",
          "orbit_customers" => nil,
          "orbit_groups" => nil
        })

      assert redirected_to(conn) == "/dashboard"
      assert Accounts.scope(Repo.one!(Operator)) == Scope.global()
    end

    test "an admin's scope is global whatever the row holds", %{conn: conn, provider: p} do
      sso_login(conn, p, %{"orbit_role" => "admin"})
      Repo.update_all(Operator, set: [customers: ~s(["acme"]), groups: ~s(["web"])])
      assert Accounts.scope(Repo.one!(Operator)) == Scope.global()
    end
  end

  describe "session" do
    defp session_for(operator) do
      Plug.Test.init_test_session(build_conn(), %{
        operator_id: operator.id,
        oidc_started_ms: Accounts.now_ms(),
        oidc_expires_at: System.os_time(:second) + 3600,
        logged_in_at: System.os_time(:second)
      })
    end

    test "re-check ends an open view when the scope changed", %{conn: conn, provider: p} do
      sso_login(conn, p, %{"orbit_role" => "operator"})
      {:ok, lv, _} = live(session_for(Repo.one!(Operator)), ~p"/hosts")
      Repo.update_all(Operator, set: [groups: ~s(["web"])])
      send(lv.pid, :oidc_session_recheck)
      assert_redirect(lv, "/sign-in")
    end

    test "a scope change at login disconnects open views", %{conn: conn, provider: p} do
      sso_login(conn, p, %{"orbit_role" => "operator"})
      op = Repo.one!(Operator)
      topic = Accounts.socket_id(op.id)
      SsmWeb.Endpoint.subscribe(topic)

      build_conn() |> sso_login(p, %{"orbit_role" => "operator", "orbit_customers" => ["acme"]})
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end
  end
end
