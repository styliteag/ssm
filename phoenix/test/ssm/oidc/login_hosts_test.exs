defmodule Ssm.OIDC.LoginHostsTest do
  @moduledoc "OIDC_LOGIN_HOSTS (oidc-client-v1 §2a): parsing and the front-channel host swap."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ssm.OIDC.LoginHosts

  @own ["ssm.example.com", "ssm.orbit.my.sty"]

  describe "parse/2" do
    test "maps own host names to IdP host names, trimmed and lowercased" do
      assert LoginHosts.parse(" SSM.orbit.my.sty = Orbit.My.Sty ", @own) ==
               %{"ssm.orbit.my.sty" => "orbit.my.sty"}
    end

    test "unset or blank is no mapping" do
      assert LoginHosts.parse(nil, @own) == %{}
      assert LoginHosts.parse("  ", @own) == %{}
    end

    test "a key that is not one of the tool's own names is ignored with an error" do
      log =
        capture_log(fn ->
          assert LoginHosts.parse("evil.example=orbit.my.sty", @own) == %{}
        end)

      assert log =~ "OIDC_LOGIN_HOSTS"
      assert log =~ "evil.example"
    end

    test "malformed entries are ignored with an error, good ones kept" do
      value =
        "ssm.orbit.my.sty=https://orbit.my.sty,ssm.example.com=sso.example.com:8443," <>
          "nohost,=x,ssm.example.com=sso/path,ssm.example.com=sso.example.com"

      log =
        capture_log(fn ->
          assert LoginHosts.parse(value, @own) == %{"ssm.example.com" => "sso.example.com"}
        end)

      assert log =~ "OIDC_LOGIN_HOSTS"
    end
  end

  describe "rewrite/3" do
    @map %{"ssm.orbit.my.sty" => "orbit.my.sty"}
    @url "https://orbit.example.com/oauth/authorize?client_id=ssm&state=abc"

    test "a mapped request host swaps only the URL's host" do
      assert LoginHosts.rewrite(@url, "SSM.orbit.my.sty", @map) ==
               "https://orbit.my.sty/oauth/authorize?client_id=ssm&state=abc"
    end

    test "scheme, port, path and query stay" do
      assert LoginHosts.rewrite(
               "https://orbit.example.com:8443/a/b?x=1",
               "ssm.orbit.my.sty",
               @map
             ) ==
               "https://orbit.my.sty:8443/a/b?x=1"
    end

    test "an unmapped request host keeps the URL" do
      assert LoginHosts.rewrite(@url, "ssm.example.com", @map) == @url
      assert LoginHosts.rewrite(@url, nil, @map) == @url
      assert LoginHosts.rewrite(@url, "ssm.orbit.my.sty", %{}) == @url
    end

    test "nil stays nil" do
      assert LoginHosts.rewrite(nil, "ssm.orbit.my.sty", @map) == nil
    end
  end
end
