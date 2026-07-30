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

  defp stub_keyfiles(host_id, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})

    MockClient.set_exec(host_id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!(entries)
    })
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

    MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy", %Result{
      stderr: "readonly: system_readonly set",
      exit_code: 1
    })

    body = conn |> post(~p"/api/v2/diffs/#{host.id}/sync") |> json_response(409)
    assert body["error"]["code"] == "SSH_READONLY"
  end
end
