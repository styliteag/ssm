defmodule SsmWeb.OIDCRpLogoutTest do
  use SsmWeb.OIDCCase

  alias Ssm.OIDC.{Config, TokenStore}

  @login_url SsmWeb.Endpoint.url() <> "/sign-in"

  defp logged_in(conn, p, extra \\ %{}) do
    conn = sso_login(conn, p, Map.merge(%{"orbit_role" => "admin"}, extra))
    assert redirected_to(conn) == "/dashboard"
    conn
  end

  defp sign_out(conn), do: conn |> recycle() |> delete(~p"/sign-out")

  defp assert_cleared(conn) do
    assert redirected_to(get(recycle(conn), ~p"/dashboard")) == "/sign-in"
  end

  # The ID token the fake provider issued for this login.
  defp issued_token(p), do: Fake.last_id_token(p)

  test "OIDC operator is sent to the end_session endpoint", %{conn: conn, provider: p} do
    conn = conn |> logged_in(p) |> sign_out()
    location = redirected_to(conn)
    uri = URI.parse(location)

    assert "#{uri.scheme}://#{uri.authority}#{uri.path}" == p.issuer <> "/logout"

    {state, query} = uri.query |> URI.decode_query() |> Map.pop("state")
    assert byte_size(state) >= 22

    assert query == %{
             "client_id" => Fake.client_id(),
             "post_logout_redirect_uri" => @login_url,
             "id_token_hint" => issued_token(p)
           }

    assert_cleared(conn)
  end

  test "an existing query of the endpoint is kept", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    # Discovery is cached by the worker; exercise the builder directly.
    url =
      Ssm.OIDC.Logout.build_url("https://idp.test/end?tenant=a", "cid", @login_url, "tok")

    assert url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.delete("state") ==
             %{
               "tenant" => "a",
               "client_id" => "cid",
               "post_logout_redirect_uri" => @login_url,
               "id_token_hint" => "tok"
             }

    assert conn |> sign_out() |> redirected_to() =~ "/logout?"
  end

  test "the id token is not stored in the clear", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    stored = get_session(conn, :oidc_id_token)
    assert is_binary(stored)
    refute stored =~ issued_token(p)
  end

  test "state is random per logout", %{conn: conn, provider: p} do
    state = fn ->
      conn
      |> logged_in(p)
      |> sign_out()
      |> redirected_to()
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()
      |> Map.get("state")
    end

    assert state.() != state.()
  end

  test "a large id token is kept server-side and still gives the hint", %{conn: conn, provider: p} do
    conn = logged_in(conn, p, %{"pad" => String.duplicate("x", 1600)})
    assert byte_size(issued_token(p)) > 1500
    assert get_session(conn, :oidc_id_token) == nil
    ref = get_session(conn, :oidc_id_token_ref)
    assert is_binary(ref)
    refute ref =~ "."
    assert TokenStore.get(ref) == issued_token(p)

    conn = sign_out(conn)
    query = conn |> redirected_to() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["id_token_hint"] == issued_token(p)
    assert TokenStore.get(ref) == nil
    assert_cleared(conn)
  end

  test "the server-side entry is gone after logout even without RP logout", %{
    conn: conn,
    provider: p
  } do
    conn = logged_in(conn, p, %{"pad" => String.duplicate("x", 1600)})
    ref = get_session(conn, :oidc_id_token_ref)
    put_config(rp_logout: false)
    conn = sign_out(conn)
    assert redirected_to(conn) == "/sign-in"
    assert TokenStore.get(ref) == nil
  end

  test "TokenStore entries expire", %{} do
    ref = TokenStore.put("tok", 0)
    Process.sleep(5)
    assert TokenStore.get(ref) == nil
  end

  test "OIDC_RP_LOGOUT=false: normal redirect", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    put_config(rp_logout: false)
    conn = sign_out(conn)
    assert redirected_to(conn) == "/sign-in"
    assert_cleared(conn)
  end

  @tag end_session: false
  test "provider without end_session_endpoint: normal redirect", %{conn: conn, provider: p} do
    conn = conn |> logged_in(p) |> sign_out()
    assert redirected_to(conn) == "/sign-in"
    assert_cleared(conn)
  end

  test "provider config unreadable: normal redirect, no crash", %{conn: conn, provider: p} do
    conn = logged_in(conn, p)
    :ok = stop_supervised(Oidcc.ProviderConfiguration.Worker)
    conn = sign_out(conn)
    assert redirected_to(conn) == "/sign-in"
    assert_cleared(conn)
  end

  @tag :tmp_dir
  test "htpasswd user: normal redirect", %{conn: conn, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".htpasswd")
    File.write!(path, "alice:" <> Bcrypt.hash_pwd_salt("pw") <> "\n")
    prev = Application.get_env(:ssm, :htpasswd_path)
    Application.put_env(:ssm, :htpasswd_path, path)
    on_exit(fn -> Application.put_env(:ssm, :htpasswd_path, prev) end)

    conn = post(conn, ~p"/session", %{"username" => "alice", "password" => "pw"})
    assert redirected_to(conn) == "/dashboard"
    conn = sign_out(conn)
    assert redirected_to(conn) == "/sign-in"
    assert_cleared(conn)
  end

  test "config default is on", %{config: config} do
    assert %Config{rp_logout: true} = config
  end
end
