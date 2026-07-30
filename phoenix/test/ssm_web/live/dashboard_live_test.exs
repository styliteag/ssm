defmodule SsmWeb.DashboardLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  setup [:setup_htpasswd, :log_in]

  test "shows entity counts", %{conn: conn} do
    user = user_fixture()
    host = host_fixture()
    _ = key_fixture(user)
    _ = authorization_fixture(user, host)

    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Dashboard"
    assert has_element?(view, "#stat-hosts .stat-value", "1")
    assert has_element?(view, "#stat-users .stat-value", "1")
    assert has_element?(view, "#stat-keys .stat-value", "1")
    assert has_element?(view, "#stat-authorizations .stat-value", "1")
  end

  test "shows recent activity entries", %{conn: conn} do
    {:ok, _} =
      Ssm.Activity.log(%{
        activity_type: "host",
        action: "created",
        target: "web1",
        actor_username: "admin",
        details: %{name: "web1"}
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#recent-activity", "created")
    assert has_element?(view, "#recent-activity", "web1")
  end

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/dashboard")
  end
end
