defmodule SsmWeb.Api.AuthApiTest do
  use SsmWeb.ConnCase, async: false

  alias Ssm.Auth.Token

  setup [:setup_htpasswd]

  test "login returns a bearer token pair in the envelope", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v2/auth/login", %{
        "username" => "admin",
        "password" => SsmWeb.ConnCase.test_password()
      })

    body = json_response(conn, 200)
    assert body["success"] == true
    assert body["error"] == nil
    assert body["data"]["token_type"] == "Bearer"
    assert {:ok, %{"sub" => "admin"}} = Token.verify(body["data"]["access_token"], "access")
    assert {:ok, _} = Token.verify(body["data"]["refresh_token"], "refresh")
  end

  test "login with wrong password is 401 INVALID_CREDENTIALS", %{conn: conn} do
    conn = post(conn, ~p"/api/v2/auth/login", %{"username" => "admin", "password" => "nope"})

    body = json_response(conn, 401)
    assert body["success"] == false
    assert body["error"]["code"] == "INVALID_CREDENTIALS"
  end

  test "login with an empty payload is 422 VALIDATION_FAILED", %{conn: conn} do
    conn = post(conn, ~p"/api/v2/auth/login", %{})

    body = json_response(conn, 422)
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert is_list(body["error"]["details"]["errors"])
  end

  test "refresh issues a new pair; an access token is refused", %{conn: conn} do
    refresh = Token.issue_refresh("admin")

    body =
      conn
      |> post(~p"/api/v2/auth/refresh", %{"refresh_token" => refresh})
      |> json_response(200)

    assert {:ok, %{"sub" => "admin"}} = Token.verify(body["data"]["access_token"], "access")

    access = Token.issue_access("admin")

    body =
      build_conn()
      |> post(~p"/api/v2/auth/refresh", %{"refresh_token" => access})
      |> json_response(401)

    assert body["error"]["code"] == "AUTH_REQUIRED"
  end

  test "me returns the token subject; logout is a no-op", %{conn: conn} do
    token = Token.issue_access("admin")

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v2/auth/me")
      |> json_response(200)

    assert body["data"] == %{"username" => "admin"}

    body = build_conn() |> post(~p"/api/v2/auth/logout") |> json_response(200)
    assert body["data"] == %{"logged_out" => true}
  end

  test "protected routes without a token are 401 AUTH_REQUIRED", %{conn: conn} do
    for path <- ["/api/v2/hosts", "/api/v2/users", "/api/v2/keys", "/api/v2/info"] do
      body = conn |> get(path) |> json_response(401)
      assert body["error"]["code"] == "AUTH_REQUIRED"
    end
  end

  test "a refresh token cannot authenticate a protected route", %{conn: conn} do
    refresh = Token.issue_refresh("admin")

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> refresh)
      |> get(~p"/api/v2/hosts")
      |> json_response(401)

    assert body["error"]["code"] == "AUTH_REQUIRED"
  end
end
