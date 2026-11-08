defmodule SsmWeb.ScopeLiveTest do
  @moduledoc """
  ADR-0012 phase 1: a scoped web operator sees and changes only hosts in its
  scope, on every page. The route test enumerates the router's LiveViews, so
  a new page must be classified here before the suite passes.
  """
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Ssm.{Activity, Authorizations, Hosts, Repo}
  alias Ssm.Ssh.MockClient

  @in_host "in-host-acme"
  @out_host "out-host-beta"
  @bare_host "bare-host-none"

  # Every LiveView route of the router, classified. Host-bearing pages show
  # host data and must apply the scope; catalog pages show the SSH user
  # catalog (all users, ADR-0012 §3) and must not leak host data either.
  @host_bearing ~w(/dashboard /hosts /authorizations /diff /activities)
  @catalog ~w(/users /keys)
  @no_host_data ~w(/sign-in /settings/api-tokens)

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "beta", name: "Beta"})
    {:ok, _} = Ssm.Groups.create_group(%{slug: "web", name: "Web"})

    in_host = member(host_fixture(%{name: @in_host}), "acme")
    out_host = member(host_fixture(%{name: @out_host}), "beta")
    bare = host_fixture(%{name: @bare_host})

    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    key_fixture(alice)
    key_fixture(bob)
    in_auth = authorization_fixture(alice, in_host, %{login: "in-login"})
    out_auth = authorization_fixture(bob, out_host, %{login: "out-login"})

    for host <- [in_host, out_host, bare] do
      Activity.log(%{
        activity_type: "host",
        action: "update",
        target: host.name,
        actor_username: "someone",
        host_id: host.id
      })
    end

    %{in_host: in_host, out_host: out_host, bare: bare, in_auth: in_auth, out_auth: out_auth}
  end

  defp member(host, customer) do
    {:ok, host} = Hosts.update_membership(host, %{customer: customer, groups: ["web"]})
    host
  end

  defp scoped(conn, p, role \\ "operator"),
    do: sso_login(conn, p, %{"orbit_role" => role, "orbit_customers" => ["acme"]})

  defp unscoped(conn, p), do: sso_login(conn, p, %{"orbit_role" => "operator"})

  describe "route coverage" do
    test "every LiveView route is classified" do
      live_paths =
        for %{plug: Phoenix.LiveView.Plug, path: path} <- SsmWeb.Router.__routes__(),
            do: path

      unclassified = live_paths -- (@host_bearing ++ @catalog ++ @no_host_data)

      assert unclassified == [],
             "classify #{inspect(unclassified)} in #{__MODULE__} and apply Ssm.Scope there"
    end

    for path <- @host_bearing ++ @catalog do
      test "#{path} leaks no out-of-scope host to a scoped operator", %{conn: conn, provider: p} do
        {:ok, lv, html} = live(scoped(conn, p), unquote(path))
        html = html <> render(lv)

        refute html =~ @out_host
        refute html =~ @bare_host
        refute html =~ "out-login"
      end
    end

    for path <- @host_bearing do
      test "#{path} shows in-scope host data", %{conn: conn, provider: p} do
        {:ok, lv, html} = live(scoped(conn, p), unquote(path))
        html = html <> render(lv)
        assert html =~ @in_host
      end

      test "#{path} shows everything to an unscoped operator", %{conn: conn, provider: p} do
        {:ok, lv, html} = live(unscoped(conn, p), unquote(path))
        html = html <> render(lv)
        assert html =~ @out_host
      end
    end
  end

  describe "dashboard" do
    test "counts only hosts and authorizations in scope", %{conn: conn, provider: p} do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/dashboard")
      assert lv |> element("#stat-hosts .stat-value") |> render() =~ ~r/>\s*1\s*</
      assert lv |> element("#stat-authorizations .stat-value") |> render() =~ ~r/>\s*1\s*</
    end
  end

  describe "hosts" do
    test "out-of-scope ids behave like missing hosts", %{conn: conn, provider: p, out_host: out} do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/hosts")
      id = to_string(out.id)

      assert render_click(lv, "edit", %{"id" => id}) =~ "Host not found"
      assert render_click(lv, "delete", %{"id" => id}) =~ "Host not found"
      assert render_click(lv, "toggle_disabled", %{"id" => id}) =~ "Host not found"
      assert render_click(lv, "test_connection", %{"id" => id}) =~ "Host not found"

      assert %{disabled: false} = Hosts.get_host(out.id)
      assert MockClient.calls().connect == []
    end

    test "in-scope hosts can be changed", %{conn: conn, provider: p, in_host: host} do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/hosts")
      assert render_click(lv, "toggle_disabled", %{"id" => to_string(host.id)}) =~ "disabled"
      assert Hosts.get_host(host.id).disabled
    end

    test "a scoped operator cannot create hosts", %{conn: conn, provider: p} do
      {:ok, lv, html} = live(scoped(conn, p), ~p"/hosts")
      refute html =~ ~s(id="new-host")
      assert render_click(lv, "new", %{}) =~ "outside your scope"

      render_submit(lv, "save", %{
        "host" => %{"name" => "sneaky", "address" => "10.9.9.9", "port" => "22"}
      })

      refute Enum.any?(Hosts.list_hosts(), &(&1.name == "sneaky"))
    end

    test "the host form never lists out-of-scope hosts", %{conn: conn, provider: p, in_host: h} do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/hosts")
      html = render_click(lv, "edit", %{"id" => to_string(h.id)})
      assert html =~ "host-form" or html =~ "<form"
      refute html =~ @out_host
    end
  end

  describe "authorizations" do
    test "filters and params cannot reach out-of-scope rows", %{
      conn: conn,
      provider: p,
      out_host: out
    } do
      {:ok, _lv, html} = live(scoped(conn, p), ~p"/authorizations?host_id=#{out.id}")
      refute html =~ "out-login"
      {:ok, _lv, html} = live(scoped(build_conn(), p), ~p"/authorizations?view=matrix")
      refute html =~ @out_host
    end

    test "writes on out-of-scope hosts are refused", %{
      conn: conn,
      provider: p,
      out_host: out,
      out_auth: out_auth,
      in_host: in_host
    } do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/authorizations")
      bob = Ssm.Users.get_user(out_auth.user_id)

      assert render_click(lv, "edit", %{"id" => to_string(out_auth.id)}) =~
               "Authorization not found"

      assert render_click(lv, "delete", %{"id" => to_string(out_auth.id)}) =~
               "Authorization not found"

      assert Authorizations.get_authorization(out_auth.id)

      render_click(lv, "new", %{})

      render_submit(lv, "save", %{
        "authorization" => %{
          "user_id" => to_string(bob.id),
          "host_id" => to_string(out.id),
          "login" => "evil"
        }
      })

      refute Authorizations.exists?(bob.id, out.id, "evil")

      render_click(lv, "bulk-open", %{})
      render_click(lv, "bulk-toggle-user", %{"id" => to_string(bob.id)})
      render_click(lv, "bulk-toggle-host", %{"id" => to_string(out.id)})
      render_click(lv, "bulk-toggle-host", %{"id" => to_string(in_host.id)})
      render_change(lv, "bulk-change", %{"bulk" => %{"login" => "bulk"}})
      assert render_click(lv, "bulk-save", %{}) =~ "outside your scope"
      refute Authorizations.exists?(bob.id, out.id, "bulk")
      refute Authorizations.exists?(bob.id, in_host.id, "bulk")
    end

    test "matrix toggles on out-of-scope hosts do nothing", %{
      conn: conn,
      provider: p,
      out_host: out,
      out_auth: out_auth
    } do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/authorizations?view=matrix&login=out-login")

      render_click(lv, "matrix-toggle", %{
        "user-id" => to_string(out_auth.user_id),
        "host-id" => to_string(out.id)
      })

      assert Authorizations.get_authorization(out_auth.id)
    end

    test "in-scope authorizations can be created and deleted", %{
      conn: conn,
      provider: p,
      in_host: host,
      in_auth: in_auth
    } do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/authorizations")
      render_click(lv, "new", %{})

      render_submit(lv, "save", %{
        "authorization" => %{
          "user_id" => to_string(in_auth.user_id),
          "host_id" => to_string(host.id),
          "login" => "fresh"
        }
      })

      assert Authorizations.exists?(in_auth.user_id, host.id, "fresh")
      assert render_click(lv, "delete", %{"id" => to_string(in_auth.id)}) =~ "deleted"
    end

    test "the CSV export is scoped", %{conn: conn, provider: p, out_host: out} do
      conn = scoped(conn, p)
      body = conn |> recycle() |> get(~p"/authorizations/export") |> response(200)
      assert body =~ "in-login"
      refute body =~ "out-login"

      body =
        build_conn()
        |> scoped(p)
        |> recycle()
        |> get(~p"/authorizations/export?host_id=#{out.id}")
        |> response(200)

      refute body =~ "out-login"
    end
  end

  describe "diff" do
    test "an out-of-scope host_id behaves like a missing one", %{
      conn: conn,
      provider: p,
      out_host: out
    } do
      {:ok, lv, html} = live(scoped(conn, p), ~p"/diff?host_id=#{out.id}")
      refute html =~ @out_host

      render_click(lv, "sync-row", %{"id" => to_string(out.id)})
      render_click(lv, "recheck-row", %{"id" => to_string(out.id)})
      assert MockClient.calls().connect == []
    end
  end

  describe "activities" do
    test "only entries of in-scope hosts and the operator's own entries", %{
      conn: conn,
      provider: p
    } do
      conn = scoped(conn, p)
      [op] = Repo.all(Ssm.Accounts.Operator)

      Activity.log(%{
        activity_type: "auth",
        action: "bulk_grant",
        target: "own-entry",
        actor_username: Ssm.Accounts.actor_label(op)
      })

      Activity.log(%{
        activity_type: "user",
        action: "create",
        target: "hostless-entry",
        actor_username: "other"
      })

      {:ok, lv, _} = live(conn, ~p"/activities")
      html = render(lv)
      assert html =~ @in_host
      assert html =~ "own-entry"
      refute html =~ "hostless-entry"
      refute html =~ @out_host
    end
  end

  describe "viewer" do
    test "a scoped viewer sees only its scope", %{conn: conn, provider: p} do
      {:ok, _lv, html} = live(scoped(conn, p, "viewer"), ~p"/hosts")
      assert html =~ @in_host
      refute html =~ @out_host
    end
  end

  describe "deleting a host" do
    test "detaches its activity entries (ids are reused by SQLite)", %{bare: bare} do
      {:ok, _} = Hosts.delete_host(bare)

      assert [] =
               Repo.all(from(l in Ssm.Activity.ActivityLog, where: l.host_id == ^bare.id))
    end
  end
end
