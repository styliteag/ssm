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

  defp store_check(host, state, attrs \\ []) do
    at = Keyword.get(attrs, :checked_at, DateTime.truncate(DateTime.utc_now(), :second))

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

  test "opening the page makes no SSH connection; Check all checks and stores", %{conn: conn} do
    synced_host = synced_setup()

    user = user_fixture()
    drifted = host_fixture(%{name: "drifted"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: nil})
    authorization_fixture(user, drifted, %{login: "root"})

    stub_keyfiles(drifted.id, [
      %{login: "root", has_pragma: false, readonly_condition: nil, keyfile: "ssh-rsa ROGUE x"}
    ])

    disabled = host_fixture(%{name: "off", disabled: true})

    {:ok, view, _html} = live(conn, ~p"/diff?view=cards")
    render_async(view)

    assert has_element?(view, "#diff-host-#{synced_host.id} .badge", "not checked")
    assert has_element?(view, "#diff-host-#{disabled.id} .badge", "disabled")
    assert MockClient.calls().exec == []
    assert MockClient.calls().connect == []

    # asks first, naming how many hosts get an SSH connection
    assert has_element?(view, ~s(#recheck-all[data-confirm*="2 hosts"]))

    view |> element("#recheck-all") |> render_click()
    render_async(view)

    assert has_element?(view, "#diff-host-#{synced_host.id} .badge", "synchronized")
    assert has_element?(view, "#diff-host-#{drifted.id} .badge", "needs sync (+1/−1)")
    assert has_element?(view, "#diff-host-#{disabled.id} .badge", "disabled")
    assert %{state: "synced"} = Ssm.Diffs.HostChecks.stored()[synced_host.id]
    assert %{state: "drift"} = Ssm.Diffs.HostChecks.stored()[drifted.id]
  end

  test "the stored check shows with its age, without any SSH", %{conn: conn} do
    host = host_fixture(%{name: "warm"})
    drift = [%{"user" => "ann", "login" => "root", "missing" => ["k1"], "extra" => []}]
    three_hours_ago = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -3 * 3600)
    store_check(host, "drift", drift: drift, checked_at: three_hours_ago)

    {:ok, view, _html} = live(conn, ~p"/diff?view=list")
    render_async(view)

    assert has_element?(view, "#diff-row-#{host.id} .badge", "needs sync (+1/−0)")
    assert has_element?(view, "#diff-row-#{host.id}", "checked 3 h ago")
    assert MockClient.calls().exec == []
  end

  test "with host_id only that host is shown and read, no host list", %{conn: conn} do
    host = synced_setup()
    other = host_fixture(%{name: "other"})
    store_check(other, "synced")

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail", "web1")
    assert has_element?(view, "#diff-back", "all hosts")
    refute has_element?(view, "#diff-list")
    refute has_element?(view, "#diff-hosts")
    refute has_element?(view, "#diff-row-#{other.id}")
    refute has_element?(view, "#recheck-all")

    contacted = MockClient.calls().exec |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    assert contacted == [host.id]
  end

  test "Key not accepted lists the hosts that refused ssm's key", %{conn: conn} do
    refused = host_fixture(%{name: "refused"})
    gone = host_fixture(%{name: "gone"})
    fine = host_fixture(%{name: "fine"})

    store_check(refused, "error",
      error_code: "auth_failed",
      error: "SSH authentication with ssm's key failed"
    )

    store_check(gone, "error", error_code: "timeout", error: "the SSH connection timed out")
    store_check(fine, "synced")

    {:ok, view, _html} = live(conn, ~p"/diff?view=list")

    assert has_element?(view, "#key-not-accepted", "1 host")

    view |> element("#diff-filter") |> render_change(%{filter: "auth"})
    assert has_element?(view, "#diff-row-#{refused.id}")
    refute has_element?(view, "#diff-row-#{gone.id}")
    refute has_element?(view, "#diff-row-#{fine.id}")

    view |> element("#diff-filter") |> render_change(%{filter: "unreachable"})
    assert has_element?(view, "#diff-row-#{gone.id}")
    refute has_element?(view, "#diff-row-#{refused.id}")

    assert MockClient.calls().exec == []
  end

  test "re-check all ignores the cache and sweeps again", %{conn: conn} do
    host = synced_setup()
    Ssm.Diffs.StatusCache.put(host.id, {:needs_sync, 1, 1})

    {:ok, view, _html} = live(conn, ~p"/diff?view=cards")
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
    # the explicit read of the selected host is stored as its check
    assert %{state: "drift"} = Ssm.Diffs.HostChecks.stored()[host.id]
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

  defp audit(action) do
    entry = Enum.find(Ssm.Activity.list(), &(&1.action == action))
    entry && {entry.actor_username, entry.target, Ssm.Activity.details(entry)}
  end

  test "a failed sync is audit-logged with the reason", %{conn: conn} do
    host = synced_setup()

    MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy", %Result{
      stderr: "readonly: system_readonly set",
      exit_code: 1
    })

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)
    view |> element("#sync-host") |> render_click()
    render_async(view)

    assert {"admin", "web1", details} = audit("sync_failed")
    assert details["written"] == ""
    assert details["error"] =~ "readonly"
  end

  test "a partial sync (user_readonly) is audit-logged with written and skipped logins",
       %{conn: conn} do
    host = synced_setup()
    other = user_fixture()
    key_fixture(other, %{key_type: "ssh-ed25519", key_base64: "LOCKEDKEY", name: "x"})
    authorization_fixture(other, host, %{login: "locked"})

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 SYNCED laptop"},
      %{
        login: "locked",
        has_pragma: true,
        readonly_condition: "keep out",
        readonly_scope: "user",
        keyfile: ""
      }
    ])

    MockClient.set_default_exec(%Result{exit_code: 0})

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)
    view |> element("#sync-host") |> render_click()
    render_async(view)

    assert render(view) =~ "Sync of web1 failed"
    assert {"admin", "web1", details} = audit("sync_partial")
    assert details["written"] == "deploy"
    assert details["skipped"] =~ ~s("locked")
    assert details["skipped"] =~ "keep out"
  end

  test "an ignored user_readonly (not owned by root) is shown on the login", %{conn: conn} do
    host = host_fixture(%{name: "ign"})

    stub_keyfiles(host.id, [
      %{login: "deploy", readonly_ignored: "user_readonly not owned by root", keyfile: ""}
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail .badge", "ignored: user_readonly not owned by root")
  end

  test "an unreadable host shows the read error, not an empty host", %{conn: conn} do
    host = host_fixture(%{name: "broken"})
    stub_version(host.id)

    MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: "not json"
    })

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "#diff-detail-read-error", "non-JSON")
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

  test "a granted key with another comment on the host is listed once, present", %{conn: conn} do
    # prod 2026-11-08: listed as "missing on host" and "not authorized" at once
    wb = user_fixture(%{username: "wb"})
    host = host_fixture(%{name: "dev"})
    material = valid_material(<<7>>)
    key_fixture(wb, %{key_type: "ssh-ed25519", key_base64: material, name: "Wim Bonis 2022"})
    authorization_fixture(wb, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: ~s(no-pty ssh-ed25519 #{material} wb@laptop\r\n)
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    html = render_async(view)

    refute html =~ "missing on host"
    refute html =~ "not authorized"
    refute has_element?(view, "[id^='allow-key-deploy-']")
  end

  test "an extra key with an options prefix still gets its Allow button", %{conn: conn} do
    roamer = user_fixture(%{username: "roamer"})
    host = host_fixture(%{name: "web1"})
    material = valid_material(<<8>>)
    key_fixture(roamer, %{key_type: "ssh-ed25519", key_base64: material, name: "roam"})

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile: ~s(from="10.0.0.0/8" ssh-ed25519 #{material} roam)
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    assert has_element?(view, "[id^='allow-key-deploy-']", "Allow (roamer)")
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

    # "Create user" is preselected, prefilled from the key comment
    assert has_element?(view, "#unknown-key-form option[value=new][selected]")
    assert has_element?(view, ~s(#unknown-key-form input[name="assign[username]"][value="stray"]))

    assert has_element?(
             view,
             ~s(#unknown-key-form input[name="assign[key_name]"][value="stray@box"])
           )

    view
    |> form("#unknown-key-form", assign: %{user_id: adopter.id, key_name: "build box"})
    |> render_change()

    refute has_element?(view, ~s(#unknown-key-form input[name="assign[username]"]))

    view
    |> form("#unknown-key-form", assign: %{user_id: adopter.id, key_name: "build box"})
    |> render_submit()

    render_async(view)

    key = Ssm.Users.get_key_by_base64(stray_material)
    assert key.user_id == adopter.id
    assert key.name == "build box"
    assert Ssm.Authorizations.exists?(adopter.id, host.id, "deploy")
  end

  test "an unknown extra key can create a new user with it", %{conn: conn} do
    authorized = user_fixture(%{username: "expected"})
    user_fixture(%{username: "taken"})
    host = host_fixture(%{name: "web1"})

    key_fixture(authorized, %{key_type: "ssh-ed25519", key_base64: "SYNCED", name: "laptop"})
    authorization_fixture(authorized, host, %{login: "deploy"})

    stray_material = valid_material(<<3>>)

    stub_keyfiles(host.id, [
      %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: nil,
        keyfile:
          "ssh-ed25519 SYNCED laptop\nssh-ed25519 #{stray_material} Oliver Tegeler ot@FW13-OT"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)
    view |> element("[id^='assign-key-deploy-']") |> render_click()

    # a taken name keeps the dialog open with the error
    view
    |> form("#unknown-key-form", assign: %{user_id: "new", username: "taken", key_name: "x"})
    |> render_submit()

    assert has_element?(view, "#unknown-key-modal #unknown-key-error", "already been taken")
    assert Ssm.Users.get_key_by_base64(stray_material) == nil

    view
    |> form("#unknown-key-form",
      assign: %{user_id: "new", username: "ot", key_name: "Oliver Tegeler ot@FW13-OT"}
    )
    |> render_submit()

    render_async(view)

    refute has_element?(view, "#unknown-key-modal")
    key = Ssm.Users.get_key_by_base64(stray_material) |> Ssm.Repo.preload(:user)
    assert key.user.username == "ot"
    assert key.name == "Oliver Tegeler ot@FW13-OT"
    assert Ssm.Authorizations.exists?(key.user_id, host.id, "deploy")

    assert Enum.any?(Ssm.Activity.list(), fn entry ->
             entry.activity_type == "user" and entry.action == "create" and entry.target == "ot"
           end)
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
      assert %{state: "synced"} = Ssm.Diffs.HostChecks.stored()[host.id]
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

    {:ok, view, _html} = live(conn, ~p"/diff?view=cards")
    view |> element("#recheck-all") |> render_click()
    render_async(view)

    view |> element("#sync-all") |> render_click()
    render_async(view)

    assert render(view) =~ "Sync all done: 1 hosts synced."

    writes =
      Enum.filter(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
        String.contains?(cmd, "set_authorized_keyfile")
      end)

    # root is the host's login user: ssm's own key is always written too
    own = Ssm.Test.OwnKeyStub.default()
    assert [{host_id, _, content}] = writes
    assert content == "ssh-ed25519 WANTED\n#{own} ssm\n"
    assert host_id == drifted.id
    refute host_id == synced_host.id
  end
end
