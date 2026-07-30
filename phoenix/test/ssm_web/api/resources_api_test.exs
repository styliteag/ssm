defmodule SsmWeb.Api.ResourcesApiTest do
  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Auth.Token

  setup %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("admin"))
    {:ok, conn: conn}
  end

  describe "hosts" do
    test "create → get → list round-trip with meta.total", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v2/hosts", %{
          "name" => "web1",
          "username" => "root",
          "address" => "10.0.0.1"
        })
        |> json_response(201)

      assert %{"id" => id, "port" => 22, "disabled" => false, "jump_via" => nil} = body["data"]

      body = conn |> get(~p"/api/v2/hosts/#{id}") |> json_response(200)
      assert body["data"]["name"] == "web1"

      body = conn |> get(~p"/api/v2/hosts") |> json_response(200)
      assert body["meta"]["total"] == 1
    end

    test "jump_via as empty string is 422", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v2/hosts", %{
          "name" => "legacy",
          "username" => "root",
          "address" => "10.0.0.9",
          "port" => 22,
          "jump_via" => ""
        })
        |> json_response(422)

      assert body["error"]["code"] == "VALIDATION_FAILED"
    end

    test "unknown jump_via is 404, self-jump is 409", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v2/hosts", %{
          "name" => "orphan",
          "username" => "root",
          "address" => "10.0.0.2",
          "jump_via" => 999_999
        })
        |> json_response(404)

      assert body["error"]["code"] == "HOST_NOT_FOUND"

      host = host_fixture()

      body =
        conn
        |> patch(~p"/api/v2/hosts/#{host.id}", %{"jump_via" => host.id})
        |> json_response(409)

      assert body["error"]["code"] == "CONFLICT"
    end

    test "duplicate name is 409 CONFLICT", %{conn: conn} do
      host_fixture(%{name: "dup"})

      body =
        conn
        |> post(~p"/api/v2/hosts", %{
          "name" => "dup",
          "username" => "root",
          "address" => "10.9.9.9"
        })
        |> json_response(409)

      assert body["error"]["code"] == "CONFLICT"
    end

    test "patch and delete", %{conn: conn} do
      host = host_fixture()

      body =
        conn |> patch(~p"/api/v2/hosts/#{host.id}", %{"comment" => "edge"}) |> json_response(200)

      assert body["data"]["comment"] == "edge"

      body = conn |> delete(~p"/api/v2/hosts/#{host.id}") |> json_response(200)
      assert body["data"] == %{"deleted_id" => host.id}

      body = conn |> get(~p"/api/v2/hosts/#{host.id}") |> json_response(404)
      assert body["error"]["code"] == "HOST_NOT_FOUND"
    end
  end

  describe "users" do
    test "crud with empty-username 422 and duplicate 409", %{conn: conn} do
      body = conn |> post(~p"/api/v2/users", %{"username" => ""}) |> json_response(422)
      assert body["error"]["code"] == "VALIDATION_FAILED"

      body = conn |> post(~p"/api/v2/users", %{"username" => "alice"}) |> json_response(201)
      assert %{"id" => id, "enabled" => true} = body["data"]

      body = conn |> post(~p"/api/v2/users", %{"username" => "alice"}) |> json_response(409)
      assert body["error"]["code"] == "CONFLICT"

      body = conn |> patch(~p"/api/v2/users/#{id}", %{"enabled" => false}) |> json_response(200)
      assert body["data"]["enabled"] == false

      assert conn |> delete(~p"/api/v2/users/#{id}") |> json_response(200)
      assert conn |> get(~p"/api/v2/users/#{id}") |> json_response(404)
    end
  end

  describe "keys" do
    test "create requires an existing owner and 16+ chars of material", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/v2/keys", %{
          "user_id" => 999_999,
          "key_type" => "ssh-ed25519",
          "key_base64" => "AAAAC3NzaC1lZDI1NTE5"
        })
        |> json_response(404)

      assert body["error"]["code"] == "USER_NOT_FOUND"

      user = user_fixture()

      body =
        conn
        |> post(~p"/api/v2/keys", %{
          "user_id" => user.id,
          "key_type" => "ssh-ed25519",
          "key_base64" => "short"
        })
        |> json_response(422)

      assert body["error"]["code"] == "VALIDATION_FAILED"
    end

    test "list filters by user_id; patch touches only name/extra_comment", %{conn: conn} do
      alice = user_fixture()
      bob = user_fixture()
      alice_key = key_fixture(alice)
      _bob_key = key_fixture(bob)

      body = conn |> get(~p"/api/v2/keys?user_id=#{alice.id}") |> json_response(200)
      assert body["meta"]["total"] == 1
      assert [%{"id" => id}] = body["data"]
      assert id == alice_key.id

      body =
        conn
        |> patch(~p"/api/v2/keys/#{alice_key.id}", %{"name" => "renamed"})
        |> json_response(200)

      assert body["data"]["name"] == "renamed"
      assert body["data"]["key_base64"] == alice_key.key_base64
    end
  end

  describe "authorizations" do
    test "create checks host and user, duplicates are 409", %{conn: conn} do
      user = user_fixture()
      host = host_fixture()

      body =
        conn
        |> post(~p"/api/v2/authorizations", %{
          "host_id" => 999_999,
          "user_id" => user.id,
          "login" => "deploy"
        })
        |> json_response(404)

      assert body["error"]["code"] == "HOST_NOT_FOUND"

      attrs = %{"host_id" => host.id, "user_id" => user.id, "login" => "deploy"}
      body = conn |> post(~p"/api/v2/authorizations", attrs) |> json_response(201)
      assert body["data"]["login"] == "deploy"

      body = conn |> post(~p"/api/v2/authorizations", attrs) |> json_response(409)
      assert body["error"]["code"] == "CONFLICT"
    end

    test "list filters by host_id and user_id", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      host = host_fixture()
      authorization_fixture(user, host, %{login: "a"})
      authorization_fixture(other, host, %{login: "b"})

      body = conn |> get(~p"/api/v2/authorizations?user_id=#{user.id}") |> json_response(200)
      assert body["meta"]["total"] == 1
      assert [%{"login" => "a"}] = body["data"]

      body = conn |> get(~p"/api/v2/authorizations?host_id=#{host.id}") |> json_response(200)
      assert body["meta"]["total"] == 2
    end
  end

  describe "activity-log" do
    test "paginates newest-first with a total; bounds are enforced", %{conn: conn} do
      for n <- 1..3 do
        Ssm.Activity.log(%{
          activity_type: "host",
          action: "create",
          target: "h#{n}",
          actor_username: "admin",
          timestamp: n
        })
      end

      body = conn |> get(~p"/api/v2/activity-log?page_size=2") |> json_response(200)
      assert body["meta"] == %{"total" => 3, "page" => 1, "page_size" => 2}
      assert [%{"target" => "h3"}, %{"target" => "h2"}] = body["data"]

      body = conn |> get(~p"/api/v2/activity-log?page=2&page_size=2") |> json_response(200)
      assert [%{"target" => "h1"}] = body["data"]

      body = conn |> get(~p"/api/v2/activity-log?page_size=0") |> json_response(422)
      assert body["error"]["code"] == "VALIDATION_FAILED"

      assert conn |> get(~p"/api/v2/activity-log?page_size=1000") |> json_response(422)
    end

    test "filters by activity_type", %{conn: conn} do
      Ssm.Activity.log(%{activity_type: "host", action: "x", target: "h", actor_username: "a"})
      Ssm.Activity.log(%{activity_type: "key", action: "x", target: "k", actor_username: "a"})

      body = conn |> get(~p"/api/v2/activity-log?activity_type=key") |> json_response(200)
      assert body["meta"]["total"] == 1
      assert [%{"activity_type" => "key"}] = body["data"]
    end
  end

  describe "info" do
    test "reports name, version, and a null alembic revision on a fresh DB", %{conn: conn} do
      body = conn |> get(~p"/api/v2/info") |> json_response(200)
      assert body["data"]["name"] == "ssm"
      assert is_binary(body["data"]["version"])
      assert body["data"]["alembic_revision"] == nil
    end
  end
end
