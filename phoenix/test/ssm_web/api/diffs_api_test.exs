defmodule SsmWeb.Api.DiffsApiTest do
  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Auth.Token
  alias Ssm.Ssh.MockClient
  alias Ssm.Ssh.Result

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup %{conn: conn} do
    start_supervised!(MockClient)
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("admin"))
    {:ok, conn: conn}
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

  test "an unreadable host is 502 SSH_CONNECT_FAILED, never an empty host", %{conn: conn} do
    host = host_fixture(%{name: "broken"})
    stub_version(host.id)

    MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: "not json"
    })

    body = conn |> get(~p"/api/v2/diffs/#{host.id}") |> json_response(502)
    assert body["success"] == false
    assert body["error"]["code"] == "SSH_CONNECT_FAILED"
    assert body["error"]["message"] =~ "non-JSON"
  end

  test "diff reports per-login items with statuses", %{conn: conn} do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: true, readonly_condition: nil, keyfile: "ssh-rsa ROGUE x"}
    ])

    body = conn |> get(~p"/api/v2/diffs/#{host.id}") |> json_response(200)

    assert body["data"]["host_name"] == "web1"
    assert [login] = body["data"]["logins"]
    assert login["login"] == "deploy"
    assert login["has_pragma"] == true

    statuses = Enum.map(login["items"], & &1["status"])
    assert "missing_on_host" in statuses
    assert "extra_on_host" in statuses
  end

  test "unknown host is 404, disabled host is 409 HOST_DISABLED", %{conn: conn} do
    body = conn |> get(~p"/api/v2/diffs/999999") |> json_response(404)
    assert body["error"]["code"] == "HOST_NOT_FOUND"

    disabled = host_fixture(%{name: "off", disabled: true})

    body = conn |> get(~p"/api/v2/diffs/#{disabled.id}") |> json_response(409)
    assert body["error"]["code"] == "HOST_DISABLED"

    body = conn |> post(~p"/api/v2/diffs/#{disabled.id}/sync") |> json_response(409)
    assert body["error"]["code"] == "HOST_DISABLED"
    assert MockClient.calls().exec == []
  end

  test "sync writes the expected keys and reports counts", %{conn: conn} do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: true, readonly_condition: nil, keyfile: ""}
    ])

    MockClient.set_default_exec(%Result{exit_code: 0})

    body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(200)

    assert body["data"]["host_name"] == "web1"
    assert body["data"]["logins"] == [%{"login" => "deploy", "written_keys" => 1}]

    write =
      Enum.find(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
        String.contains?(cmd, "set_authorized_keyfile deploy")
      end)

    assert {_, _, "ssh-ed25519 WANTED laptop\n"} = write
  end

  test "a readonly refusal aborts sync with 409 SSH_READONLY", %{conn: conn} do
    user = user_fixture()
    host = host_fixture(%{name: "web1"})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED", name: nil})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: true, readonly_condition: nil, keyfile: ""}
    ])

    MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy root", %Result{
      stderr: "readonly: system_readonly set",
      exit_code: 1
    })

    body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(409)
    assert body["error"]["code"] == "SSH_READONLY"
  end

  test "a stored key line with control characters is refused: 422 VALIDATION_FAILED", %{
    conn: conn
  } do
    user = user_fixture()
    host = host_fixture(%{name: "web1", username: "ssm-admin"})

    Ssm.Repo.insert!(%Ssm.Users.UserKey{
      user_id: user.id,
      key_type: "ssh-ed25519",
      key_base64: "BADROW\nssh-ed25519 AAAAINJECTED",
      name: "x"
    })

    authorization_fixture(user, host, %{login: "deploy"})
    stub_keyfiles(host.id, [])
    MockClient.set_default_exec(%Result{exit_code: 0})

    body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(422)
    assert body["success"] == false
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert body["error"]["message"] =~ "refused 1 stored key line"
  end

  defp audit(action) do
    entry = Enum.find(Ssm.Activity.list(), &(&1.action == action))
    entry && {entry.actor_username, entry.target, Ssm.Activity.details(entry)}
  end

  describe "sync audit log" do
    test "a successful sync is logged with the API user", %{conn: conn} do
      user = user_fixture()
      host = host_fixture(%{name: "web1"})
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "AUDIT1", name: nil})
      authorization_fixture(user, host, %{login: "deploy"})
      stub_keyfiles(host.id, [])
      MockClient.set_default_exec(%Result{exit_code: 0})

      conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(200)
      assert {"admin", "web1", %{"written" => "deploy", "keys" => 1}} = audit("sync")
    end

    test "a partial sync is 409 SSH_READONLY and logged", %{conn: conn} do
      host = host_fixture(%{name: "web2", username: "ssm-admin"})

      for login <- ["aaa", "bbb"] do
        user = user_fixture()
        key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "AUD#{login}", name: nil})
        authorization_fixture(user, host, %{login: login})
      end

      stub_keyfiles(host.id, [
        %{login: "bbb", readonly_condition: "mine", readonly_scope: "user", keyfile: ""}
      ])

      MockClient.set_default_exec(%Result{exit_code: 0})

      body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(409)
      assert body["success"] == false
      assert body["error"]["code"] == "SSH_READONLY"
      assert body["error"]["message"] =~ ~s(skipped "bbb")
      assert body["error"]["message"] =~ "written: aaa"
      assert {"admin", "web2", details} = audit("sync_partial")
      assert details["written"] == "aaa"
      assert details["skipped"] =~ ~s("bbb")
    end

    test "a refused sync (disabled host) is logged as failed", %{conn: conn} do
      host = host_fixture(%{name: "off", disabled: true})
      conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(409)
      assert {"admin", "off", %{"error" => error}} = audit("sync_failed")
      assert error =~ "disabled"
    end
  end

  describe "approved wire changes (2026-11-08)" do
    test "ssm's own key unavailable: sync is 500 INTERNAL_ERROR, nothing written", %{conn: conn} do
      Application.put_env(:ssm, :test_own_public_key, :unavailable)
      on_exit(fn -> Application.delete_env(:ssm, :test_own_public_key) end)
      user = user_fixture()
      host = host_fixture(%{name: "root-host", username: "root"})
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "OWNLESS", name: nil})
      authorization_fixture(user, host, %{login: "root"})
      stub_keyfiles(host.id, [])
      MockClient.set_default_exec(%Result{exit_code: 0})

      body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(500)
      assert body["success"] == false
      assert body["error"]["code"] == "INTERNAL_ERROR"
      assert body["error"]["message"] =~ "SSH_KEY"

      refute Enum.any?(MockClient.calls().exec, fn {_id, cmd} ->
               String.contains?(cmd, "set_authorized_keyfile")
             end)
    end

    test "a user_readonly not owned by root shows up in the sync audit entry", %{conn: conn} do
      user = user_fixture()
      host = host_fixture(%{name: "web3", username: "ssm-admin"})
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "IGN1", name: nil})
      authorization_fixture(user, host, %{login: "deploy"})

      stub_keyfiles(host.id, [
        %{login: "deploy", readonly_ignored: "user_readonly not owned by root", keyfile: ""}
      ])

      MockClient.set_default_exec(%Result{exit_code: 0})

      conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(200)
      assert {"admin", "web3", details} = audit("sync")
      assert details["ignored"] =~ ~s("deploy" \(user_readonly not owned by root\))
    end
  end

  describe "a host already syncing is refused (approved wire change, Ssm.Diffs.SyncRunner)" do
    # two logins; the second authorized_keys write pauses, so the first
    # sync is caught half-way and holds the host in the runner
    defp two_login_host do
      host = host_fixture(%{name: "busy1"})

      for login <- ["deploy", "app"] do
        user = user_fixture()
        key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "BUSY#{login}", name: nil})
        authorization_fixture(user, host, %{login: login})
      end

      stub_keyfiles(host.id, [])
      MockClient.set_default_exec(%Result{exit_code: 0})
      on_exit(Ssm.Test.PausingClient.setup(self(), 2))
      host
    end

    defp sync_rows(target),
      do:
        Ssm.Activity.list()
        |> Enum.filter(&(&1.target == target and String.starts_with?(&1.action, "sync")))
        |> Enum.map(&{&1.action, &1.actor_username})
        |> Enum.sort()

    defp assert_sync_running(conn, host) do
      conn = post(conn, ~p"/api/v2/diffs/#{host.id}/sync")
      body = json_response(conn, 409)
      assert body["success"] == false
      assert body["data"] == nil
      assert body["error"]["code"] == "SYNC_RUNNING"
      assert body["error"]["message"] =~ "busy1"
      assert get_resp_header(conn, "retry-after") == ["5"]
    end

    test "while the UI syncs the host: 409 SYNC_RUNNING, then 200 again", %{conn: conn} do
      host = two_login_host()
      ui = Task.async(fn -> Ssm.Diffs.SyncRunner.run([host], "ui-user") end)
      assert_receive {:paused, writer}, 2_000

      assert_sync_running(conn, host)

      send(writer, :go)
      assert {:ok, %{results: [{_, {:ok, _}}], busy: []}} = Task.await(ui)

      body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(200)
      assert body["data"]["host_name"] == "busy1"
      assert length(body["data"]["logins"]) == 2
      # the refused request is not a sync: no audit row of its own
      assert sync_rows("busy1") == [{"sync", "admin"}, {"sync", "ui-user"}]
    end

    test "while another API call syncs the host: 409 SYNC_RUNNING", %{conn: conn} do
      host = two_login_host()
      first = Task.async(fn -> post(conn, ~p"/api/v2/diffs/#{host.id}/sync") end)
      assert_receive {:paused, writer}, 2_000

      assert_sync_running(conn, host)

      send(writer, :go)
      assert %{"success" => true} = first |> Task.await() |> json_response(200)
      assert Ssm.Diffs.SyncRunner.status(host.id) == :idle
      assert sync_rows("busy1") == [{"sync", "admin"}]
    end
  end

  test "an unsafe ~/.ssh shows its note in the API diff (per-login read_error)", %{conn: conn} do
    host = host_fixture(%{name: "symssh"})

    stub_keyfiles(host.id, [
      %{login: "labtest", unsafe: "ssh_dir", keyfile: ""}
    ])

    body = conn |> get(~p"/api/v2/diffs/#{host.id}") |> json_response(200)
    assert [login] = body["data"]["logins"]
    assert login["read_error"] =~ "revocation blocked: unsafe ~/.ssh"
  end
end
