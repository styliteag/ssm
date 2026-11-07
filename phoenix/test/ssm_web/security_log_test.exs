defmodule SsmWeb.SecurityLogTest do
  @moduledoc "One `auth_failure` JSON line per failed authentication, never with secrets."

  use SsmWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Ssm.RateLimit

  @line ~r/\{"type":"auth_failure","app":"ssm","ts":"[^"]+","ip":"([^"]*)","reason":"([a-z_]+)","path":"([^"]*)"\}/

  setup [:setup_htpasswd]

  setup do
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)
    :ok
  end

  defp from(ip), do: %{build_conn() | remote_ip: ip}

  defp lines(log), do: Regex.scan(@line, log, capture: :all_but_first)

  test "a wrong web login password" do
    log =
      capture_log(fn ->
        post(from({203, 0, 113, 7}), ~p"/session", %{
          "username" => "admin",
          "password" => "Wr0ng-pw"
        })
      end)

    assert [["203.0.113.7", "bad_password", "/session"]] = lines(log)
    refute log =~ "Wr0ng-pw"
    refute log =~ ~s("admin")
  end

  test "a wrong API login, then the throttle lock" do
    Application.put_env(:ssm, :login_limits, failures: 1, window: 1_000_000_000)
    on_exit(fn -> Application.delete_env(:ssm, :login_limits) end)

    log =
      capture_log(fn ->
        for _ <- 1..2,
            do:
              post(from({203, 0, 113, 8}), ~p"/api/v2/auth/login", %{
                "username" => "admin",
                "password" => "nope"
              })
      end)

    assert [
             ["203.0.113.8", "bad_password", "/api/v2/auth/login"],
             ["203.0.113.8", "locked", "/api/v2/auth/login"]
           ] = lines(log)
  end

  test "an invalid refresh token" do
    log =
      capture_log(fn ->
        post(from({203, 0, 113, 9}), ~p"/api/v2/auth/refresh", %{"refresh_token" => "junk-token"})
      end)

    assert [["203.0.113.9", "bad_token", "/api/v2/auth/refresh"]] = lines(log)
    refute log =~ "junk-token"
  end

  test "an invalid mctl contract token" do
    log =
      capture_log(fn ->
        from({203, 0, 113, 10})
        |> put_req_header("authorization", "Bearer ssm_notavalidtoken")
        |> get("/api/mctl/v1/hosts")
      end)

    assert [["203.0.113.10", "bad_token", "/api/mctl/v1/hosts"]] = lines(log)
    refute log =~ "notavalid"
  end

  test "security events skip the default handler and only they reach their own" do
    {:ok, default} = :logger.get_handler_config(:default)
    assert Keyword.has_key?(default.filters, :no_security_log)

    security = %{level: :warning, msg: {:string, "x"}, meta: %{security_log: true}}
    other = %{level: :warning, msg: {:string, "x"}, meta: %{}}
    assert Ssm.SecurityLog.drop(security, nil) == :stop
    assert Ssm.SecurityLog.drop(other, nil) == :ignore
    assert Ssm.SecurityLog.only(security, nil) == security
    assert Ssm.SecurityLog.only(other, nil) == :ignore
  end
end
