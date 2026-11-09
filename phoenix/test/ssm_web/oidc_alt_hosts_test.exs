defmodule SsmWeb.OIDCAltHostsTest do
  @moduledoc "PHX_ALT_HOSTS: SSO callback and post-logout URL follow an allowed request host."
  use SsmWeb.OIDCCase

  @alt "ssm.orbit.my.sty"

  setup do
    Application.put_env(:ssm, :alt_hosts, [@alt])
    on_exit(fn -> Application.delete_env(:ssm, :alt_hosts) end)
  end

  defp on_host(conn, host), do: %{conn | host: host}

  test "login on an alt host sends that host's callback", %{conn: conn} do
    {_conn, q} = conn |> on_host(@alt) |> start_login()
    endpoint = URI.parse(SsmWeb.Endpoint.url())
    uri = URI.parse(q["redirect_uri"])

    assert uri.host == @alt
    assert uri.path == "/auth/oidc/callback"
    assert {uri.scheme, uri.port} == {endpoint.scheme, endpoint.port}
  end

  test "an unlisted host gets the endpoint's callback", %{conn: conn} do
    {_conn, q} = conn |> on_host("evil.example") |> start_login()

    assert q["redirect_uri"] == SsmWeb.Endpoint.url() <> "/auth/oidc/callback"
  end

  test "logout on an alt host returns to that host's sign-in page", %{conn: conn, provider: p} do
    conn = conn |> on_host(@alt) |> sso_login(p, %{"orbit_role" => "admin"})
    assert redirected_to(conn) == "/dashboard"

    conn = conn |> recycle() |> on_host(@alt) |> delete(~p"/sign-out")
    query = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert URI.parse(query["post_logout_redirect_uri"]).host == @alt
  end

  describe "OIDC_LOGIN_HOSTS (oidc-client-v1 §2a)" do
    setup do
      put_config(login_hosts: %{@alt => "orbit.my.sty"})
    end

    test "login on a mapped host goes to the IdP's alias name", %{conn: conn, provider: p} do
      conn = conn |> on_host(@alt) |> get("/auth/oidc/login")
      location = URI.parse(redirected_to(conn))
      issuer = URI.parse(p.issuer)

      assert location.host == "orbit.my.sty"
      assert {location.scheme, location.port} == {issuer.scheme, issuer.port}
      assert URI.decode_query(location.query)["redirect_uri"] =~ "//#{@alt}"
    end

    test "login on the endpoint's own host keeps the issuer's host", %{conn: conn, provider: p} do
      conn = get(conn, "/auth/oidc/login")

      assert URI.parse(redirected_to(conn)).host == URI.parse(p.issuer).host
    end

    test "the round trip through the alias name still signs in", %{conn: conn, provider: p} do
      conn = conn |> on_host(@alt) |> sso_login(p, %{"orbit_role" => "admin"})
      assert redirected_to(conn) == "/dashboard"
    end

    test "logout on a mapped host ends the IdP session on the alias name",
         %{conn: conn, provider: p} do
      conn = conn |> on_host(@alt) |> sso_login(p, %{"orbit_role" => "admin"})
      conn = conn |> recycle() |> on_host(@alt) |> delete(~p"/sign-out")

      assert URI.parse(redirected_to(conn)).host == "orbit.my.sty"
    end
  end

  describe "SsmWeb.Hosts.parse/1" do
    test "splits, trims, lowercases and drops empty entries" do
      assert SsmWeb.Hosts.parse(" Ssm.Orbit.My.Sty, ,other.example ") ==
               ["ssm.orbit.my.sty", "other.example"]
    end

    test "nil and blank give no hosts" do
      assert SsmWeb.Hosts.parse(nil) == []
      assert SsmWeb.Hosts.parse("  ") == []
    end
  end
end
