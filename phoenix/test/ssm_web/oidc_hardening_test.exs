defmodule SsmWeb.OIDCHardeningTest do
  use SsmWeb.OIDCCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ssm.Accounts
  alias Ssm.Accounts.Operator
  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  @event "http://schemas.openid.net/event/backchannel-logout"

  defp login(conn, p, extra \\ %{}, opts \\ []),
    do: sso_login(conn, p, Map.merge(%{"orbit_role" => "admin"}, extra), opts)

  defp operator, do: Repo.one!(Operator)

  defp session_for(operator, overrides \\ %{}) do
    base = %{
      operator_id: operator.id,
      oidc_started_ms: Accounts.now_ms(),
      oidc_expires_at: System.os_time(:second) + 3600,
      logged_in_at: System.os_time(:second)
    }

    Plug.Test.init_test_session(build_conn(), Map.merge(base, overrides))
  end

  defp logout(p, claims) do
    full =
      Map.merge(
        %{
          "iss" => p.issuer,
          "aud" => Fake.client_id(),
          "iat" => System.os_time(:second),
          "jti" => "j-" <> Integer.to_string(System.unique_integer([:positive])),
          "events" => %{@event => %{}}
        },
        claims
      )

    post(build_conn(), "/auth/oidc/backchannel-logout", %{
      "logout_token" => Fake.sign(p.key, full)
    })
  end

  describe "LiveView session lifetime (1)" do
    test "the expiry timer ends an open LiveView", %{conn: conn, provider: p} do
      login(conn, p)
      conn = session_for(operator(), %{oidc_expires_at: System.os_time(:second) + 1})
      {:ok, lv, _} = live(conn, ~p"/hosts")
      assert_redirect(lv, "/sign-in", 3000)
    end

    test "the periodic re-check ends the view when the operator is disabled", %{
      conn: conn,
      provider: p
    } do
      login(conn, p)
      {:ok, lv, _} = live(session_for(operator()), ~p"/hosts")

      Repo.update_all(Operator,
        set: [disabled_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      send(lv.pid, :oidc_session_recheck)
      assert_redirect(lv, "/sign-in")
    end

    test "re-check: sessions revoked after login", %{conn: conn, provider: p} do
      login(conn, p)

      {:ok, lv, _} =
        live(session_for(operator(), %{oidc_started_ms: Accounts.now_ms() - 10}), ~p"/hosts")

      Repo.update_all(Operator, set: [session_revoked_at: Accounts.now_ms()])
      send(lv.pid, :oidc_session_recheck)
      assert_redirect(lv, "/sign-in")
    end

    test "re-check: role changed", %{conn: conn, provider: p} do
      login(conn, p)
      {:ok, lv, _} = live(session_for(operator()), ~p"/hosts")
      Repo.update_all(Operator, set: [role: "viewer"])
      send(lv.pid, :oidc_session_recheck)
      assert_redirect(lv, "/sign-in")
    end

    test "re-check keeps a healthy session and reschedules", %{conn: conn, provider: p} do
      login(conn, p)
      {:ok, lv, _} = live(session_for(operator()), ~p"/hosts")
      send(lv.pid, :oidc_session_recheck)
      assert render(lv) =~ "Hosts"
      assert Process.alive?(lv.pid)
    end

    test "disabling and role changes broadcast a disconnect", %{conn: conn, provider: p} do
      login(conn, p)
      op = operator()
      topic = Accounts.socket_id(op.id)
      SsmWeb.Endpoint.subscribe(topic)

      {:ok, _} = Accounts.set_disabled(op, true)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

      {:ok, _} =
        Accounts.upsert_from_oidc(op.oidc_issuer, op.oidc_subject, %{name: "n", role: "viewer"})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

      {:ok, _} =
        Accounts.upsert_from_oidc(op.oidc_issuer, op.oidc_subject, %{name: "n2", role: "viewer"})

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 100
    end
  end

  describe "sid-only logout (3)" do
    test "revokes exactly that sid even when it is not the last one", %{conn: conn, provider: p} do
      a = login(conn, p, %{"sid" => "sid-a"})
      b = login(build_conn(), p, %{"sid" => "sid-b"})

      assert response(logout(p, %{"sid" => "sid-a"}), 200)

      assert a |> recycle() |> get(~p"/dashboard") |> redirected_to() == "/sign-in"
      assert b |> recycle() |> get(~p"/dashboard") |> html_response(200) =~ "Signed in as"
    end

    test "a revoked sid also ends an open LiveView at the re-check", %{conn: conn, provider: p} do
      a = login(conn, p, %{"sid" => "sid-a"})
      {:ok, lv, _} = live(a, ~p"/hosts")
      logout(p, %{"sid" => "sid-a"})
      send(lv.pid, :oidc_session_recheck)
      assert_redirect(lv, "/sign-in")
    end

    test "revocations expire with the session lifetime" do
      :ok = Accounts.revoke_sid("https://i.test", "s1", 3600)
      assert Accounts.sid_revoked?("https://i.test", "s1")
      refute Accounts.sid_revoked?("https://other.test", "s1")
      refute Accounts.sid_revoked?("https://i.test", "s2")

      :ok = Accounts.revoke_sid("https://i.test", "old", -1)
      refute Accounts.sid_revoked?("https://i.test", "old")
    end
  end

  describe "LOCAL_LOGIN=off (4)" do
    test "existing local sessions stop working", %{conn: conn} do
      setup_htpasswd(%{})
      conn = log_in_user(conn, "admin")
      assert html_response(get(conn, ~p"/dashboard"), 200) =~ "Signed in as"

      Application.put_env(:ssm, :local_login, :off)
      assert conn |> recycle() |> get(~p"/dashboard") |> redirected_to() == "/sign-in"
    end
  end

  describe "audit actor (5)" do
    test "OIDC operators are logged as name (oidc:id)", %{conn: conn, provider: p} do
      conn = login(conn, p)
      op = operator()
      label = "Test User (oidc:#{op.id})"

      assert Repo.one!(from(l in ActivityLog, where: l.action == "oidc.login")).actor_username ==
               label

      {:ok, lv, _} = live(conn, ~p"/hosts")

      {:ok, host} =
        Ssm.Hosts.create_host(%{name: "h1", address: "10.0.0.1", port: 22, username: "root"})

      render_click(lv, "delete", %{"id" => to_string(host.id)})

      assert Repo.exists?(
               from(l in ActivityLog,
                 where: l.actor_username == ^label and l.action != "oidc.login"
               )
             )
    end
  end

  describe "viewer allow-list (6)" do
    test "SSH-opening diff events are not read-only" do
      for event <- ~w(recheck recheck-row refresh) do
        refute SsmWeb.ReadOnly.allowed?("viewer", event)
      end
    end
  end

  describe "rate limits (2)" do
    test "back-channel logout has its own, higher bucket", %{conn: conn, provider: p} do
      for _ <- 1..60,
          do: post(build_conn(), "/auth/oidc/backchannel-logout", %{"logout_token" => "x"})

      # login/callback bucket untouched
      assert redirected_to(login(conn, p)) == "/dashboard"
    end

    test "login/callback exhaustion does not block back-channel logout", %{provider: p} do
      for _ <- 1..35, do: get(build_conn(), "/auth/oidc/callback")
      assert response(logout(p, %{"sid" => "s"}), 200)
    end

    test "back-channel logout is still limited eventually", %{} do
      codes = for _ <- 1..130, do: post(build_conn(), "/auth/oidc/backchannel-logout", %{}).status
      assert 429 in codes
    end

    test "X-Forwarded-For is ignored without TRUSTED_PROXIES", %{} do
      codes =
        for i <- 1..35 do
          build_conn()
          |> put_req_header("x-forwarded-for", "203.0.113.#{i}")
          |> get("/auth/oidc/callback")
          |> Map.get(:status)
        end

      assert 429 in codes
    end
  end

  describe "/api/v2 honours LOCAL_LOGIN" do
    setup do
      setup_htpasswd(%{})
      :ok
    end

    defp api_login(conn),
      do: post(conn, "/api/v2/auth/login", %{username: "admin", password: test_password()})

    test "on and admins_only: unchanged", %{conn: conn} do
      for mode <- [:on, :admins_only] do
        Application.put_env(:ssm, :local_login, mode)

        assert %{"success" => true, "data" => %{"access_token" => _}} =
                 json_response(api_login(conn), 200)
      end
    end

    test "off: login and refresh answer 401 INVALID_CREDENTIALS", %{conn: conn} do
      refresh = json_response(api_login(conn), 200)["data"]["refresh_token"]
      Application.put_env(:ssm, :local_login, :off)

      body = json_response(api_login(conn), 401)
      assert %{"success" => false, "error" => %{"code" => "INVALID_CREDENTIALS"}} = body

      body = json_response(post(conn, "/api/v2/auth/refresh", %{refresh_token: refresh}), 401)
      assert body["error"]["code"] == "INVALID_CREDENTIALS"
    end

    test "off does not touch the failed-login counters", %{conn: conn} do
      Application.put_env(:ssm, :local_login, :off)
      for _ <- 1..10, do: api_login(conn)
      Application.put_env(:ssm, :local_login, :on)
      assert json_response(api_login(conn), 200)["success"]
    end

    test "off while the provider has no configuration behaves as admins_only", %{conn: conn} do
      Application.put_env(:ssm, :local_login, :off)
      assert json_response(api_login(conn), 401)
      stop_supervised!(Oidcc.ProviderConfiguration.Worker)
      assert Ssm.OIDC.Config.local_login() == :admins_only
      assert json_response(api_login(conn), 200)["success"]
    end

    test "web form and sessions follow the same fallback", %{conn: conn} do
      Application.put_env(:ssm, :local_login, :off)
      stop_supervised!(Oidcc.ProviderConfiguration.Worker)

      assert redirected_to(
               post(conn, "/session", %{"username" => "admin", "password" => test_password()})
             ) == "/dashboard"
    end
  end

  describe "profile claims" do
    test "name and preferred_username lose control characters and are capped", %{
      conn: conn,
      provider: p
    } do
      claims = %{"name" => "Eve\u202E\nAdmin" <> String.duplicate("x", 1000)}
      assert conn |> login(p, claims) |> redirected_to() == "/dashboard"

      op = operator()
      refute op.name =~ ~r/[\x{202E}\n]/u
      assert String.starts_with?(op.name, "EveAdmin")
      assert String.length(op.name) <= 255
    end

    test "a name of only control characters falls back to the next claim", %{
      conn: conn,
      provider: p
    } do
      claims = %{"name" => "\u0007\u202E", "preferred_username" => "eve"}
      assert conn |> login(p, claims) |> redirected_to() == "/dashboard"
      assert operator().name == "eve"
    end

    test "an e-mail with control characters or over 320 characters is not stored", %{
      conn: conn,
      provider: p
    } do
      claims = %{"email" => "eve@example.com\nx", "email_verified" => true}
      assert conn |> login(p, claims) |> redirected_to() == "/dashboard"
      assert operator().email == nil
      assert operator().verified_email == nil

      long = String.duplicate("a", 320) <> "@example.com"

      assert build_conn() |> login(p, %{"email" => long}, sub: "other") |> redirected_to() ==
               "/dashboard"

      assert Repo.get_by!(Operator, oidc_subject: "other").email == nil
    end
  end

  describe "ID token iat" do
    test "older than 10 minutes is refused", %{conn: conn, provider: p} do
      claims = %{"iat" => System.os_time(:second) - 700, "exp" => System.os_time(:second) + 300}
      assert conn |> login(p, claims) |> redirected_to() == "/sign-in"
      assert Repo.all(Operator) == []
    end

    test "more than 2 minutes in the future is refused", %{conn: conn, provider: p} do
      claims = %{"iat" => System.os_time(:second) + 200}
      assert conn |> login(p, claims) |> redirected_to() == "/sign-in"
    end

    test "missing iat is refused", %{conn: conn, provider: p} do
      assert conn |> login(p, %{"iat" => nil}) |> redirected_to() == "/sign-in"
    end

    test "inside the window is accepted", %{conn: conn, provider: p} do
      now = System.os_time(:second)
      assert conn |> login(p, %{"iat" => now - 500}) |> redirected_to() == "/dashboard"

      assert build_conn() |> login(p, %{"iat" => now + 60}, sub: "other") |> redirected_to() ==
               "/dashboard"
    end
  end

  describe "JWKS refresh for unknown kid" do
    test "at most one refresh per minute, however many tokens", %{conn: conn, provider: p} do
      before = Fake.jwks_hits(p)

      for i <- 1..4 do
        build_conn() |> login(p, %{}, kid: "unknown-#{i}", sub: "s#{i}") |> redirected_to()
      end

      assert Fake.jwks_hits(p) - before <= 1
      _ = conn
    end

    test "a known kid never triggers a refresh", %{conn: conn, provider: p} do
      before = Fake.jwks_hits(p)
      assert conn |> login(p) |> redirected_to() == "/dashboard"
      assert Fake.jwks_hits(p) == before
    end
  end
end
