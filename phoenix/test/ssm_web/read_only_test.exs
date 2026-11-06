defmodule SsmWeb.ReadOnlyTest do
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest

  alias Ssm.{Hosts, Repo}
  alias Ssm.Accounts.Operator

  defp login_as(conn, provider, role),
    do: sso_login(conn, provider, %{"orbit_role" => role})

  defp host_attrs,
    do: %{name: "h1", address: "10.0.0.1", port: 22, username: "root", key_fingerprint: nil}

  describe "unit" do
    test "viewer may only send read events; others pass" do
      assert SsmWeb.ReadOnly.allowed?("viewer", "sort")
      assert SsmWeb.ReadOnly.allowed?("viewer", "filter")
      refute SsmWeb.ReadOnly.allowed?("viewer", "save")
      refute SsmWeb.ReadOnly.allowed?("viewer", "delete")
      refute SsmWeb.ReadOnly.allowed?("viewer", "something-new")
      assert SsmWeb.ReadOnly.allowed?("operator", "save")
      assert SsmWeb.ReadOnly.allowed?("admin", "delete")
    end
  end

  describe "viewer" do
    test "can open pages and sort", %{conn: conn, provider: p} do
      conn = login_as(conn, p, "viewer")
      {:ok, lv, html} = live(conn, ~p"/hosts")
      assert html =~ "Hosts"
      render_click(lv, "sort", %{"key" => "name"})
      assert Process.alive?(lv.pid)
    end

    test "write events are refused before the LiveView sees them", %{conn: conn, provider: p} do
      {:ok, host} = Hosts.create_host(host_attrs())
      conn = login_as(conn, p, "viewer")
      {:ok, lv, _} = live(conn, ~p"/hosts")

      html = render_click(lv, "delete", %{"id" => to_string(host.id)})
      assert html =~ "read-only"
      assert Hosts.get_host(host.id)

      html = render_click(lv, "new", %{})
      assert html =~ "read-only"

      render_click(lv, "toggle_disabled", %{"id" => to_string(host.id)})
      refute Hosts.get_host(host.id).disabled
    end

    test "user and authorization pages are guarded too", %{conn: conn, provider: p} do
      conn = login_as(conn, p, "viewer")
      {:ok, users, _} = live(conn, ~p"/users")
      assert render_click(users, "bulk-delete-confirm", %{}) =~ "read-only"
      {:ok, auths, _} = live(conn, ~p"/authorizations")
      assert render_click(auths, "bulk-save", %{}) =~ "read-only"
      {:ok, keys, _} = live(conn, ~p"/keys")

      assert render_click(keys, "import", %{"import" => %{"user_id" => "1", "keys_text" => "x"}}) =~
               "read-only"
    end
  end

  describe "operator and admin keep full access" do
    for role <- ~w(operator admin) do
      test "#{role} is not blocked", %{conn: conn, provider: p} do
        {:ok, host} = Hosts.create_host(host_attrs())
        conn = login_as(conn, p, unquote(role))
        {:ok, lv, _} = live(conn, ~p"/hosts")
        html = render_click(lv, "delete", %{"id" => to_string(host.id)})
        refute html =~ "read-only"
        assert Hosts.get_host(host.id) == nil
      end
    end
  end

  test "role change at the next login applies to the new session", %{conn: conn, provider: p} do
    login_as(conn, p, "admin")
    conn = login_as(build_conn(), p, "viewer")
    assert [%Operator{role: "viewer"}] = Repo.all(Operator)
    {:ok, lv, _} = live(conn, ~p"/hosts")
    assert render_click(lv, "new", %{}) =~ "read-only"
  end

  test "local htpasswd users are admins", %{conn: conn} do
    setup_htpasswd(%{})
    conn = conn |> log_in_user("admin")
    {:ok, lv, _} = live(conn, ~p"/hosts")
    refute render_click(lv, "new", %{}) =~ "read-only"
  end
end

defmodule SsmWeb.ReadOnlyDiffTest do
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Ssh.MockClient

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    %{host: host_fixture(%{name: "web1"})}
  end

  defp ssh_used?,
    do:
      MockClient.calls()
      |> Map.take([:connect, :exec, :read, :write, :probe])
      |> Map.values()
      |> Enum.any?(&(&1 != []))

  defp as(conn, p, role), do: sso_login(conn, p, %{"orbit_role" => role})

  test "viewer: mounting /diff and /diff?host_id= opens no SSH connection", %{
    conn: conn,
    provider: p,
    host: host
  } do
    conn = as(conn, p, "viewer")

    {:ok, lv, html} = live(conn, ~p"/diff")
    render_async(lv)
    assert html =~ "web1"

    {:ok, lv, html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(lv)
    assert html =~ "operator"

    refute ssh_used?()
  end

  test "viewer sees the cached status without a re-check", %{conn: conn, provider: p, host: host} do
    Ssm.Diffs.StatusCache.put(host.id, :synced)
    {:ok, lv, _} = live(as(conn, p, "viewer"), ~p"/diff")
    render_async(lv)
    refute ssh_used?()
  end

  test "operator: the same page does open SSH connections", %{conn: conn, provider: p} do
    {:ok, lv, _} = live(as(conn, p, "operator"), ~p"/diff")
    render_async(lv)
    assert ssh_used?()
  end
end
