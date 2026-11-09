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

  describe "needs attention" do
    defp store(host, state, attrs) do
      at = DateTime.truncate(DateTime.utc_now(), :second)

      Ssm.Repo.insert!(%Ssm.Diffs.HostCheck{
        host_id: host.id,
        state: state,
        logins: 1,
        drift: Keyword.get(attrs, :drift, []),
        error_code: attrs[:error_code],
        error: attrs[:error],
        checked_at: at,
        changed_at: at
      })
    end

    test "lists what to act on, each with a link", %{conn: conn} do
      Ssm.Diffs.StatusCache.reset()
      drifted = host_fixture(%{name: "drifted"})
      store(drifted, "drift", drift: [%{"login" => "deploy", "missing" => ["fp"], "extra" => []}])
      denied = host_fixture(%{name: "denied"})
      store(denied, "error", error_code: "auth_failed", error: "denied")
      down = host_fixture(%{name: "down"})
      store(down, "error", error_code: "unreachable", error: "timeout")
      pending = host_fixture(%{name: "pending"})
      :ok = Ssm.Diffs.Revocations.mark(pending.id, "test")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, ~s(#attention-drift a[href="/diff?filter=needs_sync"]), "1")
      assert has_element?(view, ~s(#attention-auth a[href="/diff?filter=auth"]), "1")
      assert has_element?(view, ~s(#attention-unreachable a[href="/diff?filter=unreachable"]))
      assert has_element?(view, ~s(#attention-pending a[href="/hosts?filter=pending"]), "1")
      # fixtures carry no host key fingerprint: all four are unpinned
      assert has_element?(view, "#attention-unpinned", "4")
    end

    test "says so when nothing needs attention", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      assert has_element?(view, "#attention-none", "Nothing needs attention")
    end
  end

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/dashboard")
  end
end
