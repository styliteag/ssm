defmodule SsmWeb.LocalLoginTest do
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest

  setup do
    setup_htpasswd(%{})
    :ok
  end

  defp form_login(conn),
    do: post(conn, "/session", %{"username" => "admin", "password" => test_password()})

  test "on: form shown, local login works", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign-in")
    assert html =~ ~s(name="username")
    assert redirected_to(form_login(conn)) == "/dashboard"
  end

  test "admins_only: htpasswd users (admins) still log in", %{conn: conn} do
    Application.put_env(:ssm, :local_login, :admins_only)
    {:ok, _lv, html} = live(conn, ~p"/sign-in")
    assert html =~ ~s(name="username")
    assert redirected_to(form_login(conn)) == "/dashboard"
  end

  test "off with OIDC: form hidden, button shown, local login refused", %{conn: conn} do
    Application.put_env(:ssm, :local_login, :off)
    {:ok, _lv, html} = live(conn, ~p"/sign-in")
    refute html =~ ~s(name="username")
    assert html =~ "oidc-login"

    resp = form_login(conn)
    assert redirected_to(resp) == "/sign-in"
    assert get(recycle(resp), ~p"/dashboard") |> redirected_to() == "/sign-in"
  end

  test "off without OIDC falls back to admins_only at boot" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {nil, :admins_only} = Ssm.OIDC.Config.from_env(%{"LOCAL_LOGIN" => "off"})
    end)
  end

  test "OIDC users cannot log in through the local form", %{conn: conn, provider: p} do
    sso_login(conn, p, %{"orbit_role" => "admin", "name" => "carol"})

    resp = post(build_conn(), "/session", %{"username" => "carol", "password" => "whatever"})
    assert redirected_to(resp) == "/sign-in"
    assert Phoenix.Flash.get(resp.assigns.flash, :error) =~ "Invalid"
  end
end
