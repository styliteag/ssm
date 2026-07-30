defmodule SsmWeb.HealthControllerTest do
  use SsmWeb.ConnCase, async: false

  test "GET /api/health answers without authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "database" => "ok", "version" => version} =
             json_response(conn, 200)

    assert is_binary(version)
  end
end
