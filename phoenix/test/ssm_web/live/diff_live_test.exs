defmodule SsmWeb.DiffLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Ssh.MockClient
  alias Ssm.Ssh.Result

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup [:setup_htpasswd, :log_in]

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp stub_version(host_id) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})
  end

  defp stub_keyfiles(host_id, entries) do
    stub_version(host_id)

    MockClient.set_exec(host_id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!(entries)
    })
  end

  defp synced_setup do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "SYNCED", name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: "ssh-ed25519 SYNCED laptop"
      }
    ])

    host
  end

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/diff")
  end

  test "shows per-host sync status after the async check", %{conn: conn} do
    synced_host = synced_setup()

    user = user_fixture()
    drifted = host_fixture(%{name: "drifted"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: nil})
    authorization_fixture(user, drifted, %{login: "root"})

    stub_keyfiles(drifted.id, [
      %{login: "root", has_pragma: false, readonly_condition: nil, keyfile: "ssh-rsa ROGUE x"}
    ])

    disabled = host_fixture(%{name: "off", disabled: true})

    {:ok, view, _html} = live(conn, ~p"/diff")
    render_async(view)

    assert has_element?(view, "#diff-host-#{synced_host.id} .badge", "synchronized")
    assert has_element?(view, "#diff-host-#{drifted.id} .badge", "needs sync (+1/−1)")
    assert has_element?(view, "#diff-host-#{disabled.id} .badge", "disabled")
  end

  test "selecting a host shows the per-login diff detail", %{conn: conn} do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: "system_readonly",
        keyfile: "ssh-rsa ROGUE old"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail", "deploy")
    assert has_element?(view, "#diff-detail .badge", "readonly: system_readonly")
    assert has_element?(view, "#diff-detail", "missing on host")
    assert has_element?(view, "#diff-detail", "not authorized")
    assert has_element?(view, "#diff-detail", "ssh-ed25519 WANTED laptop")
  end

  test "sync pushes the expected keys and logs the action", %{conn: conn} do
    host = synced_setup()
    MockClient.set_default_exec(%Result{exit_code: 0})

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    view |> element("#sync-host") |> render_click()
    render_async(view)

    assert render(view) =~ "Synced web1: 1 logins, 1 keys written."

    write =
      Enum.find(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
        String.contains?(cmd, "set_authorized_keyfile deploy")
      end)

    assert {_, _, "ssh-ed25519 SYNCED laptop\n"} = write

    assert Enum.any?(Ssm.Activity.list(), fn entry ->
             entry.action == "sync" and entry.target == "web1"
           end)
  end

  test "a readonly refusal surfaces as an error flash", %{conn: conn} do
    host = synced_setup()

    MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy", %Result{
      stderr: "readonly: system_readonly set",
      exit_code: 1
    })

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    view |> element("#sync-host") |> render_click()
    render_async(view)

    assert render(view) =~ "Sync of web1 failed"
    assert render(view) =~ "readonly"
  end

  test "disabled hosts show the disabled notice and sync stays unreachable", %{conn: conn} do
    host = host_fixture(%{name: "off", disabled: true})

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail", "Host is disabled")
    assert has_element?(view, "#sync-host[disabled]")
    assert MockClient.calls().exec == []
  end

  test "sync all only touches hosts that need it", %{conn: conn} do
    synced_host = synced_setup()

    user = user_fixture()
    drifted = host_fixture(%{name: "drifted"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: nil})
    authorization_fixture(user, drifted, %{login: "root"})

    stub_keyfiles(drifted.id, [
      %{login: "root", has_pragma: false, readonly_condition: nil, keyfile: ""}
    ])

    MockClient.set_default_exec(%Result{exit_code: 0})

    {:ok, view, _html} = live(conn, ~p"/diff")
    render_async(view)

    view |> element("#sync-all") |> render_click()
    render_async(view)

    assert render(view) =~ "Sync all done: 1 hosts synced."

    writes =
      Enum.filter(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
        String.contains?(cmd, "set_authorized_keyfile")
      end)

    assert [{host_id, _, "ssh-ed25519 WANTED\n"}] = writes
    assert host_id == drifted.id
    refute host_id == synced_host.id
  end
end
