defmodule SsmWeb.OIDCBackchannelTest do
  use SsmWeb.OIDCCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  @event "http://schemas.openid.net/event/backchannel-logout"

  defp logout_claims(p, extra \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "iss" => p.issuer,
        "aud" => Fake.client_id(),
        "iat" => now,
        "jti" => "jti-" <> Integer.to_string(System.unique_integer([:positive])),
        "events" => %{@event => %{}},
        "sid" => "sid-1"
      },
      extra
    )
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp send_logout(p, claims, key \\ nil) do
    token = Fake.sign(key || p.key, claims)
    post(build_conn(), "/auth/oidc/backchannel-logout", %{"logout_token" => token})
  end

  defp logged_in(conn, p, sid \\ "sid-1") do
    sso_login(conn, p, %{"orbit_role" => "admin", "sid" => sid})
  end

  test "ends the session of that sid; the dashboard then redirects", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    assert html_response(get(conn, ~p"/dashboard"), 200) =~ "Signed in as"

    resp = send_logout(p, logout_claims(p))
    assert response(resp, 200) == ""

    assert conn |> recycle() |> get(~p"/dashboard") |> redirected_to() == "/sign-in"
    assert [_] = Repo.all(from(l in ActivityLog, where: l.action == "oidc.backchannel_logout"))
  end

  test "by sub only, other operators stay signed in", %{conn: conn, provider: p} do
    mine = sso_login(conn, p, %{"orbit_role" => "admin"}, sub: "alice")
    other = sso_login(build_conn(), p, %{"orbit_role" => "admin"}, sub: "bob")

    assert response(send_logout(p, logout_claims(p, %{"sid" => nil, "sub" => "alice"})), 200)

    assert mine |> recycle() |> get(~p"/dashboard") |> redirected_to() == "/sign-in"
    assert other |> recycle() |> get(~p"/dashboard") |> html_response(200) =~ "Signed in as"
  end

  test "a new login after the logout works", %{conn: conn, provider: p} do
    logged_in(conn, p)
    send_logout(p, logout_claims(p))
    again = logged_in(build_conn(), p)
    assert html_response(get(again, ~p"/dashboard"), 200) =~ "Signed in as"
  end

  test "broadcasts a disconnect to the operator's LiveView topic", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    topic = get_session(conn, :live_socket_id)
    assert topic =~ "ssm_sessions:op:"
    SsmWeb.Endpoint.subscribe(topic)

    send_logout(p, logout_claims(p))
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "a LiveView mount after the logout is refused", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    send_logout(p, logout_claims(p))
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(recycle(conn), ~p"/hosts")
  end

  describe "invalid tokens answer 400 and end nothing" do
    setup %{conn: conn, provider: p} do
      %{session: logged_in(conn, p)}
    end

    defp assert_400(resp, session) do
      assert response(resp, 400) == ""
      assert session |> recycle() |> get(~p"/dashboard") |> html_response(200) =~ "Signed in as"
    end

    test "missing token", %{session: s} do
      assert_400(post(build_conn(), "/auth/oidc/backchannel-logout", %{}), s)
    end

    test "garbage token", %{session: s} do
      assert_400(
        post(build_conn(), "/auth/oidc/backchannel-logout", %{"logout_token" => "a.b.c"}),
        s
      )
    end

    test "bad signature", %{provider: p, session: s} do
      assert_400(send_logout(p, logout_claims(p), p.other_key), s)
    end

    test("wrong iss", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"iss" => "http://evil.test"})), s)
    )

    test("wrong aud", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"aud" => "other"})), s)
    )

    test("old iat", %{provider: p, session: s},
      do:
        assert_400(send_logout(p, logout_claims(p, %{"iat" => System.os_time(:second) - 400})), s)
    )

    test("missing events", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"events" => nil})), s)
    )

    test("wrong event", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"events" => %{"x" => %{}}})), s)
    )

    test("neither sid nor sub", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"sid" => nil})), s)
    )

    test("nonce present", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"nonce" => "n"})), s)
    )

    test("no jti", %{provider: p, session: s},
      do: assert_400(send_logout(p, logout_claims(p, %{"jti" => nil})), s)
    )

    test "alg none", %{provider: p, session: s} do
      token = Fake.unsigned(logout_claims(p))

      assert_400(
        post(build_conn(), "/auth/oidc/backchannel-logout", %{"logout_token" => token}),
        s
      )
    end
  end

  test "a replayed jti is refused", %{conn: conn, provider: p} do
    logged_in(conn, p)
    claims = logout_claims(p, %{"jti" => "same-jti"})
    assert response(send_logout(p, claims), 200)

    again = logged_in(build_conn(), p)
    assert response(send_logout(p, claims), 400)
    assert html_response(get(again, ~p"/dashboard"), 200) =~ "Signed in as"
  end

  test "needs no CSRF token and no session", %{provider: p} do
    resp = send_logout(p, logout_claims(p))
    assert response(resp, 200)
    assert get_resp_header(resp, "set-cookie") == []
  end

  test "is rate limited", %{provider: p} do
    codes = for _ <- 1..32, do: send_logout(p, logout_claims(p)).status
    assert 429 in codes
  end
end
