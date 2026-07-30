defmodule SsmWeb.DesignControllerTest do
  use SsmWeb.ConnCase, async: true

  test "POST /design sets the year-long design cookie and bounces to referer", %{conn: conn} do
    conn =
      conn
      |> put_req_header("referer", "http://localhost/hosts")
      |> post(~p"/design", %{"design" => "rainbow"})

    assert redirected_to(conn) == "/hosts"
    assert %{value: "rainbow", max_age: max_age} = conn.resp_cookies["ssm_design"]
    assert max_age == 60 * 60 * 24 * 365
  end

  test "POST /design with an unknown id stores the default instead", %{conn: conn} do
    conn = post(conn, ~p"/design", %{"design" => "onyx"})
    assert %{value: "orbit"} = conn.resp_cookies["ssm_design"]
    assert redirected_to(conn) == "/"
  end

  test "POST /design/mode sets the mode cookie", %{conn: conn} do
    conn = post(conn, ~p"/design/mode", %{"mode" => "light"})
    assert %{value: "light"} = conn.resp_cookies["ssm_mode"]
  end

  test "POST /design/mode with empty value deletes the cookie (Auto)", %{conn: conn} do
    conn = post(conn, ~p"/design/mode", %{"mode" => ""})
    assert %{max_age: 0} = conn.resp_cookies["ssm_mode"]
  end

  test "cookies drive data-theme on the next page render", %{conn: conn} do
    conn =
      conn
      |> put_req_cookie("ssm_design", "bench")
      |> put_req_cookie("ssm_mode", "dark")
      |> get(~p"/sign-in")

    assert html_response(conn, 200) =~ ~s(data-theme="bench-dark")
  end

  test "without cookies the default theme renders", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    assert html_response(conn, 200) =~ ~s(data-theme="orbit-dark")
  end
end
