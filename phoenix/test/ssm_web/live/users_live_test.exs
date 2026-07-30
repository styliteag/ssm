defmodule SsmWeb.UsersLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Users

  setup [:setup_htpasswd, :log_in]

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/users")
  end

  test "lists users with counts and status", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    host = host_fixture()
    _ = key_fixture(user)
    _ = authorization_fixture(user, host)
    {:ok, disabled} = Users.create_user(%{username: "bob", enabled: false})

    {:ok, view, _html} = live(conn, ~p"/users")

    assert has_element?(view, "#users-#{user.id}", "alice")
    assert has_element?(view, "#users-#{user.id} .badge", "enabled")
    assert has_element?(view, "#users-#{disabled.id} .badge", "disabled")
    assert has_element?(view, "#users-#{user.id} a[href='/keys?user_id=#{user.id}']", "1")
  end

  test "creates a user through the modal and logs it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#new-user") |> render_click()

    view
    |> form("#user-form", user: %{username: "carol", comment: "ops"})
    |> render_submit()

    assert has_element?(view, "#users", "carol")

    assert [entry] = Ssm.Activity.list()
    assert entry.activity_type == "user"
    assert entry.action == "create"
    assert entry.target == "carol"
  end

  test "rejects duplicate usernames in the modal", %{conn: conn} do
    _ = user_fixture(%{username: "dup"})

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#new-user") |> render_click()

    html =
      view
      |> form("#user-form", user: %{username: "dup"})
      |> render_submit()

    assert html =~ "has already been taken"
    assert Users.count_users() == 1
  end

  test "edits a user", %{conn: conn} do
    user = user_fixture(%{username: "old-name"})

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#edit-user-#{user.id}") |> render_click()

    view
    |> form("#user-form", user: %{username: "new-name"})
    |> render_submit()

    assert Users.get_user(user.id).username == "new-name"
    assert has_element?(view, "#users", "new-name")
  end

  test "toggle_enabled flips the flag and logs it", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#toggle-user-#{user.id}") |> render_click()
    refute Users.get_user(user.id).enabled

    assert [entry] = Ssm.Activity.list()
    assert entry.action == "disable"
  end

  test "deletes a user with keys (cascade)", %{conn: conn} do
    user = user_fixture()
    key = key_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#delete-user-#{user.id}") |> render_click()

    refute has_element?(view, "#users-#{user.id}")
    assert Users.get_user(user.id) == nil
    assert Users.get_key(key.id) == nil
  end
end
