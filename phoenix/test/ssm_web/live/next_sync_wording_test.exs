defmodule SsmWeb.NextSyncWordingTest do
  @moduledoc """
  Deleting or disabling changes the database only; the keys leave the hosts
  at their next sync. Every such question and message says so, so nobody
  takes a revoke in the UI for a revoke on the host.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  setup [:setup_htpasswd, :log_in]

  defp confirm(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-confirm")
    |> List.first("")
  end

  defp granted_user(name) do
    user = user_fixture(%{username: name})
    host = host_fixture(%{name: "web-#{name}"})
    key = key_fixture(user)
    auth = authorization_fixture(user, host, %{login: "deploy"})
    %{user: user, host: host, key: key, auth: auth}
  end

  test "deleting an SSH user", %{conn: conn} do
    %{user: user} = granted_user("alice")

    {:ok, view, _html} = live(conn, ~p"/users")

    assert confirm(view, "#delete-user-#{user.id}") =~ "next sync"
    assert view |> element("#delete-user-#{user.id}") |> render_click() =~ "next sync"
  end

  test "disabling and enabling an SSH user", %{conn: conn} do
    %{user: user} = granted_user("alice")

    {:ok, view, _html} = live(conn, ~p"/users")

    html = view |> element("#toggle-user-#{user.id}") |> render_click()
    assert html =~ "User alice disabled. Their keys leave the hosts at the next sync."

    html = view |> element("#toggle-user-#{user.id}") |> render_click()
    assert html =~ "User alice enabled. Their keys reach the hosts at the next sync."
  end

  test "deleting a key", %{conn: conn} do
    %{key: key} = granted_user("alice")

    {:ok, view, _html} = live(conn, ~p"/keys")

    assert confirm(view, "#delete-key-#{key.id}") =~ "next sync"
    assert view |> element("#delete-key-#{key.id}") |> render_click() =~ "next sync"
  end

  test "deleting an authorization", %{conn: conn} do
    %{auth: auth} = granted_user("alice")

    {:ok, view, _html} = live(conn, ~p"/access")

    assert confirm(view, "#delete-authorization-#{auth.id}") =~ "next sync"

    assert view |> element("#delete-authorization-#{auth.id}") |> render_click() =~
             "next sync"
  end
end
