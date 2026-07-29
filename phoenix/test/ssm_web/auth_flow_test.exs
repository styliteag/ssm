defmodule SsmWeb.AuthFlowTest do
  @moduledoc """
  End-to-end session auth against a temp htpasswd file: login, logout,
  protected routes, and the fingerprint invalidation that kills sessions when
  the htpasswd entry changes.
  """

  use SsmWeb.ConnCase, async: false

  @moduletag :tmp_dir

  @password "s3cret-pw"

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".htpasswd")
    File.write!(path, "admin:" <> Bcrypt.hash_pwd_salt(@password) <> "\n")

    previous = Application.get_env(:ssm, :htpasswd_path)
    Application.put_env(:ssm, :htpasswd_path, path)
    on_exit(fn -> Application.put_env(:ssm, :htpasswd_path, previous) end)

    %{htpasswd: path}
  end

  defp log_in(conn) do
    post(conn, ~p"/session", %{"username" => "admin", "password" => @password})
  end

  test "root dispatches anonymous users to sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/sign-in"
  end

  test "protected routes redirect anonymous users to sign-in", %{conn: conn} do
    conn = get(conn, ~p"/dashboard")
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
  end

  test "valid credentials create a session and land on the dashboard", %{conn: conn} do
    conn = log_in(conn)
    assert redirected_to(conn) == ~p"/dashboard"

    conn = get(conn, ~p"/dashboard")
    assert html_response(conn, 200) =~ "admin"
  end

  test "root dispatches signed-in users to the dashboard", %{conn: conn} do
    conn = log_in(conn)
    assert redirected_to(get(conn, ~p"/")) == ~p"/dashboard"
  end

  test "invalid credentials bounce back to sign-in with an error", %{conn: conn} do
    conn = post(conn, ~p"/session", %{"username" => "admin", "password" => "wrong"})
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid username or password"
  end

  test "unknown users are rejected identically", %{conn: conn} do
    conn = post(conn, ~p"/session", %{"username" => "ghost", "password" => @password})
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid username or password"
  end

  test "sign-out clears the session", %{conn: conn} do
    conn = log_in(conn)
    conn = delete(conn, ~p"/sign-out")
    assert redirected_to(conn) == ~p"/sign-in"

    assert redirected_to(get(conn, ~p"/dashboard")) == ~p"/sign-in"
  end

  test "a password change invalidates existing sessions", %{conn: conn, htpasswd: path} do
    conn = log_in(conn)
    assert html_response(get(conn, ~p"/dashboard"), 200)

    File.write!(path, "admin:" <> Bcrypt.hash_pwd_salt("rotated") <> "\n")

    assert redirected_to(get(conn, ~p"/dashboard")) == ~p"/sign-in"
  end

  test "removing the user invalidates existing sessions", %{conn: conn, htpasswd: path} do
    conn = log_in(conn)
    File.write!(path, "someone-else:" <> Bcrypt.hash_pwd_salt("x") <> "\n")

    assert redirected_to(get(conn, ~p"/dashboard")) == ~p"/sign-in"
  end

  test "signed-in users are bounced away from the sign-in page", %{conn: conn} do
    conn = log_in(conn)
    assert redirected_to(get(conn, ~p"/sign-in")) == ~p"/dashboard"
  end
end
