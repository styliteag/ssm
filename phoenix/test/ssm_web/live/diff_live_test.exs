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
    Ssm.Diffs.StatusCache.reset()
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

  test "a fresh cached status renders immediately without any SSH", %{conn: conn} do
    host = host_fixture(%{name: "warm"})
    Ssm.Diffs.StatusCache.put(host.id, :synced)

    {:ok, view, _html} = live(conn, ~p"/diff")
    render_async(view)

    assert has_element?(view, "#diff-host-#{host.id} .badge", "synchronized")
    assert MockClient.calls().exec == []
  end

  test "re-check all ignores the cache and sweeps again", %{conn: conn} do
    host = synced_setup()
    Ssm.Diffs.StatusCache.put(host.id, {:needs_sync, 1, 1})

    {:ok, view, _html} = live(conn, ~p"/diff")
    render_async(view)

    assert has_element?(view, "#diff-host-#{host.id} .badge", "needs sync")

    view |> element("#recheck-all") |> render_click()
    render_async(view)

    assert has_element?(view, "#diff-host-#{host.id} .badge", "synchronized")
    refute MockClient.calls().exec == []
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

  # KeyParser-valid material: base64 blob opening with the declared type.
  defp valid_material(payload) do
    Base.encode64(<<11::32, "ssh-ed25519", payload::binary>>)
  end

  test "an extra key of a known user gets an Allow button that grants the login", %{conn: conn} do
    authorized = user_fixture(%{username: "expected"})
    roamer = user_fixture(%{username: "roamer"})
    host = host_fixture(%{name: "web1"})

    key_fixture(authorized, %{key_type: "ssh-ed25519", key_base64: "SYNCED", name: "laptop"})
    authorization_fixture(authorized, host, %{login: "deploy"})

    roam_material = valid_material(<<1>>)
    key_fixture(roamer, %{key_type: "ssh-ed25519", key_base64: roam_material, name: "roam"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: "ssh-ed25519 SYNCED laptop\nssh-ed25519 #{roam_material} roam"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "[id^='allow-key-deploy-']", "Allow (roamer)")

    view |> element("[id^='allow-key-deploy-']") |> render_click()
    render_async(view)

    assert Ssm.Authorizations.exists?(roamer.id, host.id, "deploy")
    assert render(view) =~ "Authorized roamer for deploy on web1."

    assert Enum.any?(Ssm.Activity.list(), fn entry ->
             entry.activity_type == "auth" and entry.target == "roamer@web1:deploy"
           end)
  end

  test "an unknown extra key can be assigned to a user, granting the login too", %{conn: conn} do
    authorized = user_fixture(%{username: "expected"})
    adopter = user_fixture(%{username: "adopter"})
    host = host_fixture(%{name: "web1"})

    key_fixture(authorized, %{key_type: "ssh-ed25519", key_base64: "SYNCED", name: "laptop"})
    authorization_fixture(authorized, host, %{login: "deploy"})

    stray_material = valid_material(<<2>>)

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: "ssh-ed25519 SYNCED laptop\nssh-ed25519 #{stray_material} stray@box"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    view |> element("[id^='assign-key-deploy-']") |> render_click()
    assert has_element?(view, "#unknown-key-modal", "stray@box")

    view
    |> form("#unknown-key-form", assign: %{user_id: adopter.id})
    |> render_submit()

    render_async(view)

    key = Ssm.Users.get_key_by_base64(stray_material)
    assert key.user_id == adopter.id
    assert key.name == "stray@box"
    assert Ssm.Authorizations.exists?(adopter.id, host.id, "deploy")
  end

  test "unparseable extra keys get no action button", %{conn: conn} do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "SYNCED", name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: "ssh-ed25519 SYNCED laptop\nssh-rsa NOTBASE64! junk"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail", "not authorized")
    refute has_element?(view, "[id^='allow-key-']")
    refute has_element?(view, "[id^='assign-key-']")
  end

  describe "list view" do
    test "shows status and difference counts, searchable", %{conn: conn} do
      drifted = host_fixture(%{name: "drifted", address: "10.0.0.7"})
      clean = host_fixture(%{name: "clean", address: "10.0.0.8"})
      Ssm.Diffs.StatusCache.put(drifted.id, {:needs_sync, 2, 1})
      Ssm.Diffs.StatusCache.put(clean.id, :synced)

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")

      assert has_element?(view, "#diff-row-#{drifted.id}", "3 difference(s)")
      assert has_element?(view, "#diff-row-#{drifted.id} .badge", "needs sync")
      assert has_element?(view, "#diff-row-#{clean.id}", "0 difference(s)")

      view |> element("#diff-search") |> render_change(%{q: "drift"})
      assert has_element?(view, "#diff-row-#{drifted.id}")
      refute has_element?(view, "#diff-row-#{clean.id}")
    end

    test "per-row sync writes the host and logs", %{conn: conn} do
      host = synced_setup()
      Ssm.Diffs.StatusCache.put(host.id, :synced)
      MockClient.set_default_exec(%Result{exit_code: 0})

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")

      view |> element("#sync-row-#{host.id}") |> render_click()
      render_async(view)

      assert render(view) =~ "Synced web1"

      assert Enum.any?(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
               String.contains?(cmd, "set_authorized_keyfile deploy")
             end)
    end

    test "per-row recheck refreshes one host", %{conn: conn} do
      host = synced_setup()
      Ssm.Diffs.StatusCache.put(host.id, {:needs_sync, 5, 5})

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")
      assert has_element?(view, "#diff-row-#{host.id}", "10 difference(s)")

      view |> element("#recheck-row-#{host.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#diff-row-#{host.id} .badge", "synchronized")
    end
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
