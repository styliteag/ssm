defmodule SsmWeb.SecurityLogOIDCTest do
  @moduledoc "auth_failure lines of single sign-on."

  use SsmWeb.OIDCCase

  import ExUnit.CaptureLog

  test "a callback without a started login and a refused back-channel logout" do
    log =
      capture_log(fn ->
        get(build_conn(), "/auth/oidc/callback?code=secret-code&state=x")
        post(build_conn(), "/auth/oidc/backchannel-logout", %{"logout_token" => "junk"})
      end)

    assert log =~ ~s("reason":"oidc_failed","path":"/auth/oidc/callback")
    assert log =~ ~s("reason":"oidc_failed","path":"/auth/oidc/backchannel-logout")
    refute log =~ "secret-code"
  end
end
