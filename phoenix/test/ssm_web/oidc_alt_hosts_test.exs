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
