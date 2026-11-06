defmodule Ssm.OIDC.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ssm.OIDC.Config

  setup do
    path = Path.join(System.tmp_dir!(), "oidc-secret-#{System.unique_integer([:positive])}")
    File.write!(path, "s3cret-value\n")
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp env(path, extra \\ %{}) do
    Map.merge(
      %{
        "OIDC_ISSUER" => "https://sso.example.test/",
        "OIDC_CLIENT_ID" => "ssm",
        "OIDC_CLIENT_SECRET_FILE" => path
      },
      extra
    )
  end

  test "unset issuer: OIDC off, local login on" do
    assert {nil, :on} = Config.from_env(%{})
  end

  test "valid env with defaults", %{path: path} do
    assert {%Config{} = c, :on} = Config.from_env(env(path))
    assert c.issuer == "https://sso.example.test"
    assert c.client_secret == "s3cret-value"
    assert c.role_claim == "orbit_role"
    assert c.customers_claim == "orbit_customers"
    assert c.login_label == "Login with SSO"
    assert c.session_max_hours == 8
  end

  test "overrides and role map order", %{path: path} do
    {c, _} =
      Config.from_env(
        env(path, %{
          "OIDC_ROLE_CLAIM" => "r",
          "OIDC_LOGIN_LABEL" => "Go",
          "OIDC_SESSION_MAX_HOURS" => "2",
          "OIDC_ROLE_MAP" => "ops=operator, root=admin"
        })
      )

    assert c.role_claim == "r"
    assert c.login_label == "Go"
    assert c.session_max_hours == 2
    assert c.role_map == [{"ops", "operator"}, {"root", "admin"}]
  end

  test "missing client id keeps OIDC off and logs an error", %{path: path} do
    log =
      capture_log(fn ->
        assert {nil, :on} = Config.from_env(env(path) |> Map.delete("OIDC_CLIENT_ID"))
      end)

    assert log =~ "OIDC disabled"
    refute log =~ "s3cret-value"
  end

  test "unreadable secret file keeps OIDC off" do
    capture_log(fn ->
      assert {nil, _} = Config.from_env(env("/nonexistent/secret"))
    end)
  end

  test "group/other readable secret file warns without leaking it", %{path: path} do
    File.chmod!(path, 0o644)
    log = capture_log(fn -> Config.from_env(env(path)) end)
    assert log =~ "readable by group/other"
    refute log =~ "s3cret-value"
  end

  test "LOCAL_LOGIN modes", %{path: path} do
    assert {_, :admins_only} = Config.from_env(env(path, %{"LOCAL_LOGIN" => "admins_only"}))
    assert {_, :off} = Config.from_env(env(path, %{"LOCAL_LOGIN" => "off"}))
  end

  test "LOCAL_LOGIN=off without OIDC becomes admins_only and logs an error" do
    log =
      capture_log(fn ->
        assert {nil, :admins_only} = Config.from_env(%{"LOCAL_LOGIN" => "off"})
      end)

    assert log =~ "admins_only"
  end

  test "LOCAL_LOGIN=off with broken OIDC config also falls back", %{path: path} do
    capture_log(fn ->
      env = env(path, %{"LOCAL_LOGIN" => "off"}) |> Map.delete("OIDC_CLIENT_ID")
      assert {nil, :admins_only} = Config.from_env(env)
    end)
  end

  test "LOCAL_LOGIN is case-insensitive", %{path: path} do
    assert {_, :admins_only} = Config.from_env(env(path, %{"LOCAL_LOGIN" => " Admins_Only "}))
    assert {_, :off} = Config.from_env(env(path, %{"LOCAL_LOGIN" => "OFF"}))
    assert {_, :on} = Config.from_env(env(path, %{"LOCAL_LOGIN" => "On"}))
  end

  test "invalid LOCAL_LOGIN becomes admins_only and logs an error", %{path: path} do
    log =
      capture_log(fn ->
        assert {_, :admins_only} = Config.from_env(env(path, %{"LOCAL_LOGIN" => "bogus"}))
      end)

    assert log =~ "LOCAL_LOGIN"
  end

  test "empty or unset LOCAL_LOGIN is on", %{path: path} do
    assert {_, :on} = Config.from_env(env(path, %{"LOCAL_LOGIN" => ""}))
    assert {_, :on} = Config.from_env(env(path))
  end
end
