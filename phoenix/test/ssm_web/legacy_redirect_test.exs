defmodule SsmWeb.LegacyRedirectTest do
  use SsmWeb.ConnCase, async: true

  test "/authorizations moves permanently to /access, query string kept", %{conn: conn} do
    conn = get(conn, "/authorizations?user_id=7&view=matrix")

    assert conn.status == 301
    assert redirected_to(conn, 301) == "/access?user_id=7&view=matrix"
  end

  test "the old CSV export path moves to the new one", %{conn: conn} do
    conn = get(conn, "/authorizations/export?host_id=3")

    assert redirected_to(conn, 301) == "/access/export?host_id=3"
  end

  test "no query string, no question mark", %{conn: conn} do
    assert conn |> get("/authorizations") |> redirected_to(301) == "/access"
  end
end
