defmodule SsmWeb.AuthorizationExportControllerTest do
  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  setup [:setup_htpasswd, :log_in]

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    conn = get(conn, ~p"/authorizations/export")
    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "downloads the list as quoted CSV", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    host = host_fixture(%{name: "web1", address: "10.0.0.1"})
    _auth = authorization_fixture(user, host, %{login: "deploy", options: ~s(no-pty,from="x")})

    conn = get(conn, ~p"/authorizations/export")

    assert response_content_type(conn, :csv) =~ "text/csv"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="authorizations-#{Date.utc_today()}.csv")
           ]

    [header, line] = String.split(response(conn, 200), "\n")
    assert header == ~s("User","Host","Login Account","SSH Options","User Enabled","Host Address")
    assert line == ~s("alice","web1","deploy","no-pty,from=""x""","Yes","10.0.0.1")
  end

  test "honors the user_id filter", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    host = host_fixture()
    _a = authorization_fixture(alice, host, %{login: "a"})
    _b = authorization_fixture(bob, host, %{login: "b"})

    conn = get(conn, ~p"/authorizations/export?user_id=#{alice.id}")

    body = response(conn, 200)
    assert body =~ "alice"
    refute body =~ "bob"
  end
end
