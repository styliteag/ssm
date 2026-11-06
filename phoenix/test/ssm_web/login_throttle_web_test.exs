defmodule SsmWeb.LoginThrottleWebTest do
  @moduledoc """
  Failed-login limit on both password surfaces: the web form
  (`POST /session`) and `POST /api/v2/auth/login`.
  """

  use SsmWeb.ConnCase, async: false

  alias Ssm.{Activity, RateLimit}
  alias SsmWeb.ConnCase

  # Fixed windows: a window boundary mid-test would reset a counter.
  @window 1_000_000_000

  setup [:setup_htpasswd]

  setup do
    RateLimit.reset()
    previous = Application.get_env(:ssm, :login_limits)
    previous_proxies = Application.get_env(:ssm, :trusted_proxies)
    Application.put_env(:ssm, :login_limits, failures: 3, window: @window)

    on_exit(fn ->
      RateLimit.reset()
      Application.put_env(:ssm, :trusted_proxies, previous_proxies || [])

      if previous,
        do: Application.put_env(:ssm, :login_limits, previous),
        else: Application.delete_env(:ssm, :login_limits)
    end)

    :ok
  end

  defp from(ip), do: %{build_conn() | remote_ip: ip}
  defp good, do: ConnCase.test_password()

  defp ui(conn, user, pass),
    do: post(conn, ~p"/session", %{"username" => user, "password" => pass})

  defp api(conn, user, pass),
    do: post(conn, ~p"/api/v2/auth/login", %{"username" => user, "password" => pass})

  defp ui_error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  describe "web form" do
    test "locks after 3 failures; even the right password is refused, generic message" do
      for _ <- 1..3 do
        conn = from({10, 0, 0, 1}) |> ui("admin", "nope")
        assert redirected_to(conn) == ~p"/sign-in"
        assert ui_error(conn) == "Invalid username or password."
      end

      conn = from({10, 0, 0, 1}) |> ui("admin", good())
      assert redirected_to(conn) == ~p"/sign-in"
      assert ui_error(conn) == "Too many failed attempts, try again later"
      # no session was created: the password was never checked
      assert redirected_to(get(recycle(conn), ~p"/dashboard")) == ~p"/sign-in"
    end

    test "unknown user and wrong password are indistinguishable and both count" do
      from({10, 0, 0, 1}) |> ui("admin", "nope") |> ui_error() |> then(&assert(&1 =~ "Invalid"))
      from({10, 0, 0, 1}) |> ui("ghost", "nope") |> ui_error() |> then(&assert(&1 =~ "Invalid"))
      from({10, 0, 0, 1}) |> ui("ghost2", "nope")

      conn = from({10, 0, 0, 1}) |> ui("ghost3", "x")
      assert ui_error(conn) =~ "Too many failed attempts"
    end

    test "username lock holds across IPs and case; other users unaffected" do
      from({10, 0, 0, 1}) |> ui("admin", "nope")
      from({10, 0, 0, 2}) |> ui("ADMIN", "nope")
      from({10, 0, 0, 3}) |> ui("admin", "nope")

      conn = from({10, 0, 0, 4}) |> ui("admin", good())
      assert ui_error(conn) =~ "Too many failed attempts"
    end

    test "success resets the username counter" do
      from({10, 0, 0, 1}) |> ui("admin", "nope")
      from({10, 0, 0, 2}) |> ui("admin", "nope")
      assert redirected_to(from({10, 0, 0, 3}) |> ui("admin", good())) == ~p"/dashboard"

      from({10, 0, 0, 4}) |> ui("admin", "nope")
      from({10, 0, 0, 5}) |> ui("admin", "nope")
      assert redirected_to(from({10, 0, 0, 6}) |> ui("admin", good())) == ~p"/dashboard"
    end

    test "missing params count as a failed attempt" do
      for _ <- 1..3, do: from({10, 0, 0, 1}) |> post(~p"/session", %{})
      conn = from({10, 0, 0, 1}) |> ui("admin", good())
      assert ui_error(conn) =~ "Too many failed attempts"
    end

    test "client IP comes from TrustedProxies" do
      Application.put_env(:ssm, :trusted_proxies, "192.168.0.0/16")

      for n <- 1..3 do
        from({192, 168, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> ui("u#{n}", "nope")
      end

      locked =
        from({192, 168, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> ui("fresh", good())

      assert ui_error(locked) =~ "Too many failed attempts"

      # another real client behind the same proxy is fine
      other =
        from({192, 168, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.8")
        |> ui("admin", good())

      assert redirected_to(other) == ~p"/dashboard"
    end

    test "lock is audited without the password" do
      for _ <- 1..3, do: from({10, 0, 0, 1}) |> ui("admin", "hunter2-secret")
      entries = Activity.list(search: "login_locked")
      assert entries != []
      refute inspect(entries) =~ "hunter2-secret"
    end
  end

  describe "audit username" do
    defp lock_details do
      [%{} = entry | _] =
        Activity.list(search: "login_locked")
        |> Enum.filter(&(Activity.details(&1)["subject"] == "username"))

      Activity.details(entry)
    end

    test "known user is logged by name" do
      for _ <- 1..3, do: from({10, 0, 0, 1}) |> api("Admin", "nope")
      assert lock_details()["username"] == "admin"
    end

    test "unknown name (maybe a password) is logged only as a hash" do
      for n <- 1..3, do: from({10, 0, 0, n}) |> api("hunter2-secret", "x")
      details = lock_details()
      assert "sha256:" <> hex = details["username"]
      assert byte_size(hex) == 16
      refute inspect(Activity.list()) =~ "hunter2-secret"
    end
  end

  describe "api login" do
    test "locks after 3 failures: 429 RATE_LIMITED envelope + Retry-After, password unchecked" do
      for _ <- 1..3 do
        assert from({10, 0, 0, 1}) |> api("admin", "nope") |> json_response(401)
      end

      conn = from({10, 0, 0, 1}) |> api("admin", good())
      body = json_response(conn, 429)
      assert body["success"] == false
      assert body["data"] == nil
      assert body["error"]["code"] == "RATE_LIMITED"
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) in 1..@window
    end

    test "per-username lock across IPs, success resets, unknown user same as wrong password" do
      a = from({10, 0, 0, 1}) |> api("admin", "nope") |> json_response(401)
      b = from({10, 0, 0, 2}) |> api("ghost", "nope") |> json_response(401)
      assert a == b

      assert from({10, 0, 0, 3}) |> api("admin", good()) |> json_response(200)

      from({10, 0, 0, 4}) |> api("admin", "nope")
      from({10, 0, 0, 5}) |> api("admin", "nope")
      assert from({10, 0, 0, 6}) |> api("admin", good()) |> json_response(200)

      for ip <- [{10, 0, 1, 1}, {10, 0, 1, 2}, {10, 0, 1, 3}],
          do: from(ip) |> api("Admin", "nope")

      assert from({10, 0, 1, 4}) |> api("admin", good()) |> json_response(429)
    end

    test "validation failures do not count; client IP comes from TrustedProxies" do
      for _ <- 1..5,
          do: from({10, 0, 0, 1}) |> post(~p"/api/v2/auth/login", %{}) |> json_response(422)

      assert from({10, 0, 0, 1}) |> api("admin", good()) |> json_response(200)

      Application.put_env(:ssm, :trusted_proxies, "192.168.0.0/16")
      proxied = fn xff -> from({192, 168, 0, 1}) |> put_req_header("x-forwarded-for", xff) end

      for n <- 1..3, do: proxied.("203.0.113.7") |> api("u#{n}", "nope")
      assert proxied.("203.0.113.7") |> api("fresh", good()) |> json_response(429)
      assert proxied.("203.0.113.8") |> api("admin", good()) |> json_response(200)
    end

    test "the two surfaces share the counters" do
      from({10, 0, 0, 1}) |> ui("admin", "nope")
      from({10, 0, 0, 1}) |> api("admin", "nope")
      from({10, 0, 0, 1}) |> ui("admin", "nope")
      assert from({10, 0, 0, 1}) |> api("admin", good()) |> json_response(429)
    end

    test "refresh endpoint is untouched by the login limit" do
      for _ <- 1..3, do: from({10, 0, 0, 1}) |> api("admin", "nope")
      token = Ssm.Auth.Token.issue_refresh("admin")

      assert from({10, 0, 0, 1})
             |> post(~p"/api/v2/auth/refresh", %{"refresh_token" => token})
             |> json_response(200)
    end
  end
end
