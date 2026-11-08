defmodule SsmWeb.Api.GrantRowsApiTest do
  @moduledoc """
  ADR-0012 §5: authorization rows made by a grant are read-only for
  `/api/v2` too (409 `CONFLICT`); manual rows behave as before. The wire
  format of the rows is unchanged.
  """
  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Auth.Token
  alias Ssm.Authorizations.Authorization
  alias Ssm.{Customers, Grants, Hosts, Repo, Scope}

  setup %{conn: conn} do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, host} = Hosts.update_membership(host_fixture(), %{customer: "acme"})
    alice = user_fixture(%{username: "alice"})

    {:ok, _grant} =
      Grants.create_grant(%{role: "admin", scope: Scope.global(), actor: "admin"}, %{
        ssh_user_id: alice.id,
        customer_id: acme.id,
        login: "deploy"
      })

    row = Repo.get_by!(Authorization, host_id: host.id)
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("admin"))
    {:ok, conn: conn, row: row}
  end

  test "a grant row is listed with the usual fields", %{conn: conn, row: row} do
    body = conn |> get(~p"/api/v2/authorizations") |> json_response(200)
    assert body["success"] == true
    assert body["meta"]["total"] == 1
    assert [%{"id" => id, "login" => "deploy"} = data] = body["data"]
    assert id == row.id
    refute Map.has_key?(data, "grant_id")
  end

  test "DELETE of a grant row is 409 CONFLICT", %{conn: conn, row: row} do
    body = conn |> delete(~p"/api/v2/authorizations/#{row.id}") |> json_response(409)
    assert body["success"] == false
    assert body["error"]["code"] == "CONFLICT"
    assert Repo.get(Authorization, row.id)
  end

  test "PATCH of a grant row is 409 CONFLICT", %{conn: conn, row: row} do
    body =
      conn
      |> patch(~p"/api/v2/authorizations/#{row.id}", %{"login" => "other"})
      |> json_response(409)

    assert body["error"]["code"] == "CONFLICT"
    assert Repo.get!(Authorization, row.id).login == "deploy"
  end

  test "unauthenticated is 401 AUTH_REQUIRED", %{row: row} do
    body = build_conn() |> delete(~p"/api/v2/authorizations/#{row.id}") |> json_response(401)
    assert body["error"]["code"] == "AUTH_REQUIRED"
  end
end
