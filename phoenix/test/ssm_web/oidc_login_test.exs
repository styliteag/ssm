defmodule SsmWeb.OIDCLoginTest do
  use SsmWeb.OIDCCase

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ssm.Accounts
  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  defp dashboard_ok?(conn), do: html_response(get(conn, ~p"/dashboard"), 200) =~ "Signed in as"
  defp refused?(conn), do: redirected_to(conn) == "/sign-in"

  defp audit(action), do: Repo.all(from(l in ActivityLog, where: l.action == ^action))

  describe "happy path per suite role" do
    for role <- ~w(admin operator viewer) do
      test "role #{role} signs in", %{conn: conn, provider: p} do
        conn = sso_login(conn, p, %{"orbit_role" => unquote(role), "amr" => ["pwd", "otp"]})
        assert redirected_to(conn) == "/dashboard"
        assert dashboard_ok?(conn)

        [op] = Repo.all(Ssm.Accounts.Operator)
        assert op.role == unquote(role)
        assert op.oidc_subject == "sub-1"
        assert op.source == "oidc"

        [entry] = audit("oidc.login")
        assert entry.actor_username == "Test User (oidc:#{op.id})"
        meta = Jason.decode!(entry.meta)
        assert meta["role"] == unquote(role)
        assert meta["amr"] == ["pwd", "otp"]
      end
    end

    test "session records sid, sub and expiry", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin", "sid" => "sid-9"})
      assert get_session(conn, :oidc_sid) == "sid-9"
      assert get_session(conn, :oidc_sub) == "sub-1"
      assert_in_delta get_session(conn, :oidc_expires_at), System.os_time(:second) + 8 * 3600, 5
    end

    test "returns to the stored same-origin path", %{conn: conn, provider: p} do
      conn = conn |> Plug.Test.init_test_session(%{user_return_to: "/hosts"})
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      assert redirected_to(conn) == "/hosts"
    end

    test "ignores an off-site return path", %{conn: conn, provider: p} do
      conn = conn |> Plug.Test.init_test_session(%{user_return_to: "//evil.test/x"})
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      assert redirected_to(conn) == "/dashboard"
    end
  end

  describe "refusals" do
    test "unknown role", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "wizard"})
      assert refused?(conn)
      assert Repo.all(Ssm.Accounts.Operator) == []
      assert [e] = audit("oidc.login_refused")
      assert Jason.decode!(e.meta)["reason"] == "unknown_role"
    end

    test "missing role", %{conn: conn, provider: p} do
      assert conn |> sso_login(p, %{}) |> refused?()
    end

    test "suite role customer is refused in ssm", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "customer", "orbit_customers" => ["acme"]})
      assert refused?(conn)
      assert Repo.all(Ssm.Accounts.Operator) == []
      assert Jason.decode!(hd(audit("oidc.login_refused")).meta)["reason"] == "customer_role"
    end

    test "generic message, no details in the flash", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "wizard"})
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert flash =~ "Single sign-on failed"
      refute flash =~ "wizard"
    end

    test "wrong aud", %{conn: conn, provider: p} do
      assert conn |> sso_login(p, %{"orbit_role" => "admin", "aud" => "other"}) |> refused?()
      assert Repo.all(Ssm.Accounts.Operator) == []
    end

    test "wrong iss", %{conn: conn, provider: p} do
      claims = %{"orbit_role" => "admin", "iss" => "http://evil.test"}
      assert conn |> sso_login(p, claims) |> refused?()
    end

    test "expired id token", %{conn: conn, provider: p} do
      claims = %{"orbit_role" => "admin", "exp" => System.os_time(:second) - 600}
      assert conn |> sso_login(p, claims) |> refused?()
    end

    test "bad signature", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"}, sign_with: p.other_key)
      assert refused?(conn)
      assert Repo.all(Ssm.Accounts.Operator) == []
    end

    test "nonce mismatch", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"}, nonce: "not-the-nonce")
      assert refused?(conn)
    end

    test "state mismatch", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"}, state: "forged")
      assert refused?(conn)
      assert Repo.all(Ssm.Accounts.Operator) == []
    end

    test "callback without a started login", %{conn: conn} do
      assert conn |> get("/auth/oidc/callback", %{"code" => "x", "state" => "y"}) |> refused?()
    end

    test "provider error parameter", %{conn: conn} do
      {conn, _} = start_login(conn)
      assert conn |> get("/auth/oidc/callback", %{"error" => "access_denied"}) |> refused?()
    end

    test "state is single use", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :oidc_state) == nil
    end

    test "alg none is rejected", %{conn: conn, provider: p} do
      {conn, q} = start_login(conn)
      claims = Fake.claims(p, "sub-1", %{"orbit_role" => "admin", "nonce" => q["nonce"]})
      Fake.put_code(p, "none-code", claims, sign_with: :none)

      assert refused?(
               get(conn, "/auth/oidc/callback", %{"code" => "none-code", "state" => q["state"]})
             )
    end

    test "disabled operator stays refused until re-enabled", %{conn: conn, provider: p} do
      sso_login(conn, p, %{"orbit_role" => "admin"})
      [op] = Repo.all(Ssm.Accounts.Operator)
      {:ok, _} = Accounts.set_disabled(op, true)

      assert build_conn() |> sso_login(p, %{"orbit_role" => "admin"}) |> refused?()
      assert Jason.decode!(hd(audit("oidc.login_refused")).meta)["reason"] == "disabled"

      {:ok, _} = Accounts.set_disabled(Repo.get!(Ssm.Accounts.Operator, op.id), false)

      assert build_conn() |> sso_login(p, %{"orbit_role" => "admin"}) |> redirected_to() ==
               "/dashboard"
    end

    test "no token, code or secret in logs", %{conn: conn, provider: p} do
      log =
        capture_log(fn ->
          conn |> sso_login(p, %{"orbit_role" => "wizard"}, nonce: "bad") |> refused?()
        end)

      refute log =~ Fake.client_secret()
      refute log =~ "code-"
      refute log =~ "eyJ"
    end
  end

  describe "OIDC_ROLE_MAP" do
    test "groups claim used when role claim is missing; first map entry wins", %{
      conn: conn,
      provider: p
    } do
      put_config(role_map: [{"ops", "operator"}, {"root", "admin"}])
      conn = sso_login(conn, p, %{"groups" => ["root", "ops"]})
      assert redirected_to(conn) == "/dashboard"
      assert [%{role: "operator"}] = Repo.all(Ssm.Accounts.Operator)
    end

    test "role claim wins over the map", %{conn: conn, provider: p} do
      put_config(role_map: [{"ops", "operator"}])
      sso_login(conn, p, %{"orbit_role" => "viewer", "groups" => ["ops"]})
      assert [%{role: "viewer"}] = Repo.all(Ssm.Accounts.Operator)
    end

    test "no matching group refuses", %{conn: conn, provider: p} do
      put_config(role_map: [{"ops", "operator"}])
      assert conn |> sso_login(p, %{"groups" => ["other"]}) |> refused?()
    end
  end

  describe "upsert" do
    test "repeat login overwrites role, name, email and customers", %{conn: conn, provider: p} do
      {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
      {:ok, _} = Ssm.Customers.create_customer(%{slug: "beta", name: "Beta"})

      sso_login(conn, p, %{
        "orbit_role" => "operator",
        "orbit_customers" => ["acme"],
        "name" => "A"
      })

      assert [%{role: "operator", name: "A"} = op] = Repo.all(Ssm.Accounts.Operator)
      assert Accounts.customers(op) == ["acme"]

      build_conn()
      |> sso_login(p, %{
        "orbit_role" => "viewer",
        "orbit_customers" => ["beta"],
        "name" => "B",
        "email" => "new@x.test"
      })

      assert [%{role: "viewer", name: "B", email: "new@x.test"} = op] =
               Repo.all(Ssm.Accounts.Operator)

      assert Accounts.customers(op) == ["beta"]
    end

    test "wildcard customers; unknown slugs grant nothing and are logged", %{
      conn: conn,
      provider: p
    } do
      sso_login(conn, p, %{"orbit_role" => "operator", "orbit_customers" => ["*"]})
      assert [op] = Repo.all(Ssm.Accounts.Operator)
      assert Accounts.customers(op) == ["*"]

      log =
        capture_log(fn ->
          build_conn()
          |> sso_login(p, %{"orbit_role" => "operator", "orbit_customers" => ["ghost"]})
        end)

      assert log =~ "ghost"
      assert [op] = Repo.all(Ssm.Accounts.Operator)
      assert Accounts.customers(op) == []
    end

    test "same e-mail as a local user is a separate account", %{conn: conn, provider: p} do
      setup_htpasswd(%{})

      conn =
        sso_login(conn, p, %{
          "orbit_role" => "viewer",
          "email" => "admin@example.test",
          "name" => "admin"
        })

      assert redirected_to(conn) == "/dashboard"
      assert [%{role: "viewer"}] = Repo.all(Ssm.Accounts.Operator)
      # local admin still works untouched and is a different identity
      local =
        build_conn() |> post("/session", %{"username" => "admin", "password" => test_password()})

      assert redirected_to(local) == "/dashboard"
      assert length(Repo.all(Ssm.Accounts.Operator)) == 1
    end

    test "key is (issuer, sub): same sub, other issuer is another operator", %{provider: p} do
      {:ok, a} = Accounts.upsert_from_oidc(p.issuer, "s", %{name: "n", role: "admin"})
      {:ok, b} = Accounts.upsert_from_oidc("https://other.test", "s", %{name: "n", role: "admin"})
      refute a.id == b.id
    end
  end

  describe "session lifetime" do
    test "ends after OIDC_SESSION_MAX_HOURS", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      assert dashboard_ok?(conn)

      expired =
        Plug.Test.init_test_session(build_conn(), %{
          operator_id: get_session(conn, :operator_id),
          oidc_started_ms: Accounts.now_ms(),
          oidc_expires_at: System.os_time(:second) - 1,
          logged_in_at: System.os_time(:second)
        })

      assert expired |> get(~p"/dashboard") |> refused?()
    end

    test "a LiveView mount past the expiry redirects to sign-in", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      assert {:ok, _lv, _html} = live(conn, ~p"/dashboard")

      expired =
        Plug.Test.init_test_session(build_conn(), %{
          operator_id: get_session(conn, :operator_id),
          oidc_started_ms: Accounts.now_ms(),
          oidc_expires_at: System.os_time(:second) - 1,
          logged_in_at: System.os_time(:second)
        })

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(expired, ~p"/dashboard")
    end

    test "disabling an operator ends an open session", %{conn: conn, provider: p} do
      conn = sso_login(conn, p, %{"orbit_role" => "admin"})
      [op] = Repo.all(Ssm.Accounts.Operator)
      {:ok, _} = Accounts.set_disabled(op, true)
      assert conn |> recycle() |> get(~p"/dashboard") |> refused?()
    end
  end

  describe "OIDC off" do
    test "no button, routes 404", %{conn: conn} do
      Application.put_env(:ssm, :oidc_config, nil)
      {:ok, _lv, html} = live(conn, ~p"/sign-in")
      refute html =~ "oidc-login"
      assert get(conn, "/auth/oidc/login").status == 404
      assert get(conn, "/auth/oidc/callback").status == 404
      assert post(conn, "/auth/oidc/backchannel-logout", %{"logout_token" => "x"}).status == 404
    end
  end

  describe "login page and rate limit" do
    test "shows the configured button", %{conn: conn} do
      put_config(login_label: "Sign in with Orbit")
      {:ok, _lv, html} = live(conn, ~p"/sign-in")
      assert html =~ "Sign in with Orbit"
      assert html =~ ~s(href="/auth/oidc/login")
    end

    test "/auth/oidc/* is rate limited per IP", %{conn: conn} do
      statuses = for _ <- 1..32, do: get(conn, "/auth/oidc/callback").status
      assert 429 in statuses
    end
  end
end
