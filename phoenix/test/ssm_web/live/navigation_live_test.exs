defmodule SsmWeb.NavigationLiveTest do
  @moduledoc """
  Cross-links between the pages, the SSH user page, and list searches that
  live in the URL (`?q=…`), so they survive a reload and navigating back.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  setup [:setup_htpasswd, :log_in]

  setup do
    start_supervised!(Ssm.Ssh.MockClient)
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  test "the SSH user page shows keys, access with host links, and links out", %{conn: conn} do
    user = user_fixture(%{username: "wim"})
    key = key_fixture(user, %{name: "laptop"})
    host = host_fixture(%{name: "web1"})
    auth = authorization_fixture(user, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/users/#{user.id}")

    assert has_element?(view, "#user-name", "wim")
    assert has_element?(view, "#user-key-#{key.id}", "laptop")
    assert has_element?(view, "#copy-user-key-#{key.id}[data-copy]")

    assert has_element?(
             view,
             ~s(#user-auth-#{auth.id} a[href="/diff?host_id=#{host.id}"]),
             "web1"
           )

    assert has_element?(view, ~s(#user-keys-link[href="/keys?user_id=#{user.id}"]))
    assert has_element?(view, ~s(#user-grants-link[href="/grants?user_id=#{user.id}"]))
  end

  test "an unknown SSH user id goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/users"}}} = live(conn, ~p"/users/999999")
  end

  test "users: names link to the user page, the search filters via the URL", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    user_fixture(%{username: "bob"})

    {:ok, view, _html} = live(conn, ~p"/users")
    assert has_element?(view, ~s(a[href="/users/#{alice.id}"]), "alice")

    view |> form("#users-search", %{"q" => "ali"}) |> render_change()
    assert_patch(view, ~p"/users?q=ali")
    assert has_element?(view, "a", "alice")
    refute has_element?(view, "a", "bob")

    {:ok, view, _html} = live(conn, ~p"/users?q=bob")
    assert has_element?(view, "a", "bob")
    refute has_element?(view, "a", "alice")
  end

  test "hosts: names link to the diff, search and filter live in the URL", %{conn: conn} do
    web = host_fixture(%{name: "web1"})
    host_fixture(%{name: "db1"})

    {:ok, view, _html} = live(conn, ~p"/hosts?filter=all")
    assert has_element?(view, ~s(a[href="/diff?host_id=#{web.id}"]), "web1")

    view |> form("#hosts-search", %{"q" => "web"}) |> render_change()
    assert_patch(view, ~p"/hosts?filter=all&q=web")
    assert has_element?(view, "a", "web1")
    refute has_element?(view, "a", "db1")
  end

  test "keys: the search is part of the URL", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    key_fixture(user, %{name: "laptop"})

    {:ok, view, _html} = live(conn, ~p"/keys")
    view |> form("#keys-search", %{"q" => "lap"}) |> render_change()
    assert_patch(view, ~p"/keys?q=lap")
    assert has_element?(view, ~s(a[href="/users/#{user.id}"]), "alice")
  end

  test "activity entries link to their target", %{conn: conn} do
    host = host_fixture(%{name: "web1"})

    Ssm.Activity.log(%{
      activity_type: "host",
      action: "update",
      target: "web1",
      actor_username: "admin",
      host_id: host.id
    })

    Ssm.Activity.log(%{
      activity_type: "user",
      action: "create",
      target: "alice",
      actor_username: "admin"
    })

    {:ok, view, _html} = live(conn, ~p"/activities")
    assert has_element?(view, ~s(a[href="/diff?host_id=#{host.id}"]), "web1")
    assert has_element?(view, ~s(a[href="/users?q=alice"]), "alice")
  end
end
