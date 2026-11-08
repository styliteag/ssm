defmodule SsmWeb.Api.ManagedLoginsApiTest do
  @moduledoc """
  `/api/v2/hosts/{id}/managed-logins` (additive): list a host's managed
  logins with their authorization count, and `DELETE …/{login}` to forget
  one that has no authorization and no file on the host. Audited.
  """

  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Activity, Authorizations}
  alias Ssm.Auth.Token
  alias Ssm.Ssh.{MockClient, Result}

  setup %{conn: conn} do
    start_supervised!(MockClient)
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_default_exec(%Result{stdout: payload})
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("admin"))
    {:ok, conn: conn}
  end

  defp revoked(host, login) do
    auth = authorization_fixture(user_fixture(), host, %{login: login})
    {:ok, _} = Authorizations.delete_authorization(auth)
  end

  defp has_keyfile(host, login, answer) do
    MockClient.set_exec(host.id, "sh .ssm/script.sh has_keyfile #{login}", %Result{
      stdout: answer
    })
  end

  test "401 AUTH_REQUIRED without a token" do
    for conn <- [
          build_conn() |> get(~p"/api/v2/hosts/1/managed-logins"),
          build_conn() |> delete(~p"/api/v2/hosts/1/managed-logins/old")
        ] do
      body = json_response(conn, 401)
      assert body["success"] == false
      assert body["error"]["code"] == "AUTH_REQUIRED"
    end
  end

  test "lists managed logins with their authorization count", %{conn: conn} do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    revoked(host, "old")

    body = conn |> get(~p"/api/v2/hosts/#{host.id}/managed-logins") |> json_response(200)

    assert body["success"] == true
    assert body["error"] == nil
    assert body["meta"]["total"] == 2

    assert body["data"] == [
             %{"login" => "deploy", "authorizations" => 1},
             %{"login" => "old", "authorizations" => 0}
           ]
  end

  test "forgets a login without authorizations and file, audited", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    revoked(host, "old")
    has_keyfile(host, "old", "no")

    body = conn |> delete(~p"/api/v2/hosts/#{host.id}/managed-logins/old") |> json_response(200)

    assert body["success"] == true
    assert body["data"] == %{"host_id" => host.id, "login" => "old", "forgotten" => true}
    assert Authorizations.managed_logins(host.id) == []
    assert %{action: "forget_login", actor_username: "admin"} = hd(Activity.list())
  end

  test "domain errors map to stable codes", %{conn: conn} do
    host = host_fixture()
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    revoked(host, "old")
    has_keyfile(host, "old", "yes")
    disabled = host_fixture(%{disabled: true})
    revoked(disabled, "old")

    cases = [
      {~p"/api/v2/hosts/999999/managed-logins/old", 404, "HOST_NOT_FOUND"},
      {~p"/api/v2/hosts/abc/managed-logins/old", 422, "VALIDATION_FAILED"},
      {~p"/api/v2/hosts/#{host.id}/managed-logins/nope", 404, "MANAGED_LOGIN_NOT_FOUND"},
      {~p"/api/v2/hosts/#{host.id}/managed-logins/deploy", 409, "CONFLICT"},
      {~p"/api/v2/hosts/#{host.id}/managed-logins/old", 409, "CONFLICT"},
      {~p"/api/v2/hosts/#{disabled.id}/managed-logins/old", 409, "HOST_DISABLED"}
    ]

    for {path, status, code} <- cases do
      body = conn |> delete(path) |> json_response(status)
      assert body["success"] == false, path
      assert body["error"]["code"] == code, path
    end

    body = conn |> get(~p"/api/v2/hosts/999999/managed-logins") |> json_response(404)
    assert body["error"]["code"] == "HOST_NOT_FOUND"
  end

  test "an unreadable host is 502 SSH_CONNECT_FAILED", %{conn: conn} do
    host = host_fixture()
    revoked(host, "old")
    has_keyfile(host, "old", "garbage")

    body = conn |> delete(~p"/api/v2/hosts/#{host.id}/managed-logins/old") |> json_response(502)
    assert body["error"]["code"] == "SSH_CONNECT_FAILED"
    assert Authorizations.managed_logins(host.id) == ["old"]
  end
end
