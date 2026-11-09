defmodule SsmWeb.DiffRemoveLoginTest do
  @moduledoc """
  "Remove login from host" on the diff page: for a login the host does not
  know, an admin deletes its manual authorizations on that host and ssm
  stops managing it (`ManagedLogins.forget/5` with `unknown_login: :forget`).
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Authorizations
  alias Ssm.Ssh.MockClient
  alias Ssm.Ssh.Result

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup [:setup_htpasswd, :log_in]

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  defp stub_host(host, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!(entries)
    })

    MockClient.set_exec(host.id, "sh .ssm/script.sh has_keyfile tm", %Result{
      stdout: "unknown\n",
      exit_code: 1
    })
  end

  defp unknown_tm(host) do
    stub_host(host, [%{login: "tm", has_pragma: false, keyfile: "", home_state: "unknown_login"}])
  end

  test "removes a login the host does not know", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    user = user_fixture(%{username: "tom"})
    authorization_fixture(user, host, %{login: "tm"})
    unknown_tm(host)

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(
             view,
             ~s(#remove-login-tm[data-confirm*="Remove login tm from web1?"])
           )

    assert has_element?(view, ~s(#remove-login-tm[data-confirm*="1 authorization"]))
    assert has_element?(view, ~s(#remove-login-tm[data-confirm*="directory outage"]))

    view |> element("#remove-login-tm") |> render_click()
    render_async(view)

    assert render(view) =~ "Removed login tm from web1."
    assert Authorizations.list_authorizations(host_id: host.id) == []
    assert Authorizations.managed_logins(host.id) == []

    actions = Enum.map(Ssm.Activity.list(), & &1.action)
    assert "delete" in actions
    assert "forget_login" in actions
  end

  test "no button for a login whose home is only missing", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    authorization_fixture(user_fixture(), host, %{login: "tm"})
    stub_host(host, [%{login: "tm", has_pragma: false, keyfile: "", home_state: "home_missing"}])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    refute has_element?(view, "#remove-login-tm")
  end
end
