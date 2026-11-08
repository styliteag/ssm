defmodule SsmWeb.Api.DiffNotesApiTest do
  @moduledoc """
  `GET /api/v2/diffs/{host_id}`: every login carries `notes` — the notes the
  diff page shows (unsafe files, blocked revocations, an ignored
  `user_readonly`, dropped host restrictions, invalid stored options), each
  `{kind, text, line}`. Additive: the existing fields are unchanged.
  """

  use SsmWeb.ConnCase, async: false

  import Ecto.Query
  import Ssm.Fixtures

  alias Ssm.Auth.Token
  alias Ssm.Authorizations.Authorization
  alias Ssm.Repo
  alias Ssm.Ssh.{MockClient, Result}

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

  defp grant(host, login, base64, options \\ nil) do
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: base64, name: "laptop"})
    authorization_fixture(user, host, %{login: login, options: options})
  end

  defp login(body, name), do: Enum.find(body["data"]["logins"], &(&1["login"] == name))

  test "401 AUTH_REQUIRED without a token" do
    body = build_conn() |> get(~p"/api/v2/diffs/1") |> json_response(401)
    assert body["success"] == false
    assert body["error"]["code"] == "AUTH_REQUIRED"
  end

  test "every login carries the notes the diff page shows", %{conn: conn} do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "restricted", "NARROW", "no-pty")
    legacy = grant(host, "legacy", "LEGACY")

    from(a in Authorization, where: a.id == ^legacy.id)
    |> Repo.update_all(set: [options: "bogus-option"])

    stub_keyfiles(host.id, [
      %{
        login: "restricted",
        has_pragma: true,
        keyfile: ~s(from="10.0.0.1" ssh-ed25519 NARROW laptop)
      },
      %{login: "legacy", has_pragma: true, keyfile: "ssh-ed25519 LEGACY laptop"},
      %{
        login: "frozen",
        has_pragma: true,
        readonly_condition: "user_readonly (root-owned)",
        readonly_scope: "user",
        keyfile: "ssh-ed25519 STALE x"
      },
      %{
        login: "mine",
        has_pragma: true,
        readonly_ignored: "user_readonly not owned by root",
        keyfile: ""
      },
      %{login: "linked", has_pragma: false, unsafe: "symlink", keyfile: ""},
      %{login: "dirlink", has_pragma: false, unsafe: "ssh_dir", keyfile: ""}
    ])

    conn = get(conn, ~p"/api/v2/diffs/#{host.id}")
    body = json_response(conn, 200)
    assert conn.status == 200
    assert body["success"] == true

    assert [
             %{
               "kind" => "drops_host_restriction",
               "text" => "drops host restriction: from",
               "line" => ~s(from="10.0.0.1" ssh-ed25519 NARROW laptop)
             }
           ] = login(body, "restricted")["notes"]

    assert [
             %{
               "kind" => "invalid_stored_options",
               "text" => "invalid stored options",
               "line" => "ssh-ed25519 LEGACY laptop"
             }
           ] = login(body, "legacy")["notes"]

    assert [
             %{
               "kind" => "revocation_blocked",
               "text" => "revocation blocked by user_readonly",
               "line" => "ssh-ed25519 STALE x"
             }
           ] = login(body, "frozen")["notes"]

    assert [
             %{
               "kind" => "readonly_ignored",
               "text" => "ignored: user_readonly not owned by root",
               "line" => nil
             }
           ] = login(body, "mine")["notes"]

    assert [%{"kind" => "unsafe", "text" => "unsafe authorized_keys (symlink)" <> _}] =
             login(body, "linked")["notes"]

    assert [
             %{"kind" => "unsafe", "text" => "unsafe ~/.ssh: not read, not written"},
             %{"kind" => "revocation_blocked", "text" => "revocation blocked: unsafe ~/.ssh"}
           ] = login(body, "dirlink")["notes"]
  end

  test "notes are additive: a login without notes keeps exactly the old fields plus []",
       %{conn: conn} do
    host = host_fixture()
    grant(host, "deploy", "PLAIN")

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 PLAIN laptop"}
    ])

    body = conn |> get(~p"/api/v2/diffs/#{host.id}") |> json_response(200)
    assert body["success"] == true
    assert [login] = body["data"]["logins"]

    assert Map.keys(login) |> Enum.sort() ==
             ~w(has_pragma items login notes read_error readonly_condition)

    assert login["notes"] == []
    assert [%{"status" => "present", "line" => "ssh-ed25519 PLAIN laptop"}] = login["items"]
    assert Map.keys(hd(login["items"])) |> Enum.sort() == ~w(line status)
  end
end
