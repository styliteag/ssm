defmodule SsmWeb.Api.WriteAuditApiTest do
  @moduledoc """
  Every successful `/api/v2` write (host, SSH user, key, authorization:
  create, update, delete) leaves exactly one activity-log entry, with the
  token's subject as actor and `via: "api"`; a refused write leaves none.
  """

  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Activity
  alias Ssm.Auth.Token

  setup %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("api-bot"))
    {:ok, conn: conn}
  end

  # runs `fun`, returns the entries it added (oldest first)
  defp new_entries(fun) do
    before = MapSet.new(Activity.list(limit: 1000), & &1.id)
    fun.()
    Activity.list(limit: 1000) |> Enum.reject(&(&1.id in before)) |> Enum.reverse()
  end

  defp assert_one(entries, type, action, target) do
    assert [entry] = entries
    assert {entry.activity_type, entry.action, entry.target} == {type, action, target}
    assert entry.actor_username == "api-bot"
    assert Activity.details(entry)["via"] == "api"
    entry
  end

  test "hosts: create, update, delete", %{conn: conn} do
    entries =
      new_entries(fn ->
        post(conn, ~p"/api/v2/hosts", %{"name" => "web1", "username" => "root", "address" => "a"})
        |> json_response(201)
      end)

    entry = assert_one(entries, "host", "create", "web1")
    host = Ssm.Hosts.get_host(entry.host_id)
    assert Activity.details(entry)["address"] == "a"

    entries =
      new_entries(fn ->
        patch(conn, ~p"/api/v2/hosts/#{host.id}", %{"comment" => "x"}) |> json_response(200)
      end)

    assert_one(entries, "host", "update", "web1")

    entries =
      new_entries(fn -> delete(conn, ~p"/api/v2/hosts/#{host.id}") |> json_response(200) end)

    assert_one(entries, "host", "delete", "web1")
  end

  test "users: create, update, delete", %{conn: conn} do
    entries =
      new_entries(fn ->
        post(conn, ~p"/api/v2/users", %{"username" => "alice"}) |> json_response(201)
      end)

    entry = assert_one(entries, "user", "create", "alice")
    id = entry.user_id
    assert is_integer(id)

    entries =
      new_entries(fn ->
        patch(conn, ~p"/api/v2/users/#{id}", %{"comment" => "c"}) |> json_response(200)
      end)

    assert_one(entries, "user", "update", "alice")

    entries = new_entries(fn -> delete(conn, ~p"/api/v2/users/#{id}") |> json_response(200) end)
    entry = assert_one(entries, "user", "delete", "alice")
    assert entry.user_id == nil
  end

  test "keys: create, update, delete", %{conn: conn} do
    user = user_fixture()

    entries =
      new_entries(fn ->
        post(conn, ~p"/api/v2/keys", %{
          "user_id" => user.id,
          "key_type" => "ssh-ed25519",
          "key_base64" => "AAAAC3NzaC1lZDI1NTE5",
          "name" => "laptop"
        })
        |> json_response(201)
      end)

    entry = assert_one(entries, "key", "create", "laptop")
    assert entry.user_id == user.id
    [key] = Ssm.Users.list_keys() |> Enum.filter(&(&1.user_id == user.id))

    entries =
      new_entries(fn ->
        patch(conn, ~p"/api/v2/keys/#{key.id}", %{"name" => "desk"}) |> json_response(200)
      end)

    assert_one(entries, "key", "update", "desk")

    entries =
      new_entries(fn -> delete(conn, ~p"/api/v2/keys/#{key.id}") |> json_response(200) end)

    assert_one(entries, "key", "delete", "desk")
  end

  test "authorizations: create, update, delete", %{conn: conn} do
    user = user_fixture(%{username: "bob"})
    host = host_fixture(%{name: "db1"})

    entries =
      new_entries(fn ->
        post(conn, ~p"/api/v2/authorizations", %{
          "host_id" => host.id,
          "user_id" => user.id,
          "login" => "deploy"
        })
        |> json_response(201)
      end)

    entry = assert_one(entries, "auth", "create", "bob@db1:deploy")
    assert {entry.host_id, entry.user_id} == {host.id, user.id}
    [auth] = Ssm.Authorizations.list_authorizations() |> Enum.filter(&(&1.host_id == host.id))

    entries =
      new_entries(fn ->
        patch(conn, ~p"/api/v2/authorizations/#{auth.id}", %{"login" => "app"})
        |> json_response(200)
      end)

    assert_one(entries, "auth", "update", "bob@db1:app")

    entries =
      new_entries(fn ->
        delete(conn, ~p"/api/v2/authorizations/#{auth.id}") |> json_response(200)
      end)

    entry = assert_one(entries, "auth", "delete", "bob@db1:app")
    assert entry.user_id == nil
  end

  test "a refused write leaves no entry", %{conn: conn} do
    assert [] =
             new_entries(fn ->
               post(conn, ~p"/api/v2/hosts", %{"name" => ""}) |> json_response(422)
               patch(conn, ~p"/api/v2/users/999999", %{"comment" => "x"}) |> json_response(404)
               delete(conn, ~p"/api/v2/keys/999999") |> json_response(404)

               post(conn, ~p"/api/v2/authorizations", %{
                 "host_id" => 999_999,
                 "user_id" => 999_999,
                 "login" => "x"
               })
               |> json_response(404)
             end)
  end
end
