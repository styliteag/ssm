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

  test "selecting rows shows the bulk toolbar", %{conn: conn} do
    a = user_fixture(%{username: "alice"})
    b = user_fixture(%{username: "bob"})

    {:ok, view, _html} = live(conn, ~p"/users")

    refute has_element?(view, "#bulk-toolbar")

    view |> element("#select-user-#{a.id}") |> render_click()
    assert has_element?(view, "#bulk-toolbar", "1 selected")
    assert has_element?(view, "#bulk-merge[disabled]")

    view |> element("#select-user-#{b.id}") |> render_click()
    assert has_element?(view, "#bulk-toolbar", "2 selected")
    refute has_element?(view, "#bulk-merge[disabled]")
  end

  test "merges selected users into an existing target", %{conn: conn} do
    target = user_fixture(%{username: "canonical"})
    source = user_fixture(%{username: "dupe"})
    _key = key_fixture(source)
    host = host_fixture()
    _auth = authorization_fixture(source, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#select-user-#{target.id}") |> render_click()
    view |> element("#select-user-#{source.id}") |> render_click()
    view |> element("#bulk-merge") |> render_click()

    view
    |> element("#merge-form")
    |> render_change(%{merge: %{mode: "existing", target_id: target.id}})

    view |> element("#merge-form") |> render_submit()

    assert Users.get_user(source.id) == nil
    assert [_] = Users.list_keys(user_id: target.id)
    assert Ssm.Authorizations.exists?(target.id, host.id, "deploy")

    assert Enum.any?(Ssm.Activity.list(), &(&1.action == "merge" and &1.target == "canonical"))
  end

  test "merges selected users into a brand-new user", %{conn: conn} do
    a = user_fixture(%{username: "a"})
    b = user_fixture(%{username: "b"})
    _key = key_fixture(a)

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#select-user-#{a.id}") |> render_click()
    view |> element("#select-user-#{b.id}") |> render_click()
    view |> element("#bulk-merge") |> render_click()

    view
    |> element("#merge-form")
    |> render_change(%{merge: %{mode: "new", username: "merged"}})

    view |> element("#merge-form") |> render_submit()

    assert Users.get_user(a.id) == nil
    assert Users.get_user(b.id) == nil
    merged = Enum.find(Users.list_users(), &(&1.username == "merged"))
    assert merged
    assert [_] = Users.list_keys(user_id: merged.id)
  end

  test "splits keys into a new user", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    _keep = key_fixture(user)
    move = key_fixture(user)
    host = host_fixture()
    _auth = authorization_fixture(user, host, %{login: "root"})

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#split-user-#{user.id}") |> render_click()
    assert has_element?(view, "#split-form input[name='split[username]'][value='alice copy']")

    view |> element("#split-key-#{move.id}") |> render_click()
    view |> element("#split-form") |> render_submit()

    new_user = Enum.find(Users.list_users(), &(&1.username == "alice copy"))
    assert new_user
    assert [_] = Users.list_keys(user_id: new_user.id)
    assert [_] = Users.list_keys(user_id: user.id)
    assert Ssm.Authorizations.exists?(new_user.id, host.id, "root")

    assert Enum.any?(Ssm.Activity.list(), &(&1.action == "split" and &1.target == "alice copy"))
  end

  test "split refuses to take every key", %{conn: conn} do
    user = user_fixture()
    only_a = key_fixture(user)
    only_b = key_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#split-user-#{user.id}") |> render_click()
    view |> element("#split-key-#{only_a.id}") |> render_click()
    view |> element("#split-key-#{only_b.id}") |> render_click()

    html = view |> element("#split-form") |> render_submit()

    assert html =~ "must keep at least one key"
    assert length(Users.list_users()) == 1
  end

  test "bulk delete removes the selected users and their data", %{conn: conn} do
    a = user_fixture(%{username: "a"})
    b = user_fixture(%{username: "b"})
    keep = user_fixture(%{username: "keep"})
    key = key_fixture(a)
    host = host_fixture()
    _auth = authorization_fixture(a, host)

    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#select-user-#{a.id}") |> render_click()
    view |> element("#select-user-#{b.id}") |> render_click()
    view |> element("#bulk-delete") |> render_click()

    assert has_element?(view, "#bulk-delete-modal", "1 SSH key(s)")

    view |> element("#bulk-delete-confirm") |> render_click()

    assert Users.get_user(a.id) == nil
    assert Users.get_user(b.id) == nil
    assert Users.get_user(keep.id)
    assert Users.get_key(key.id) == nil

    deletes = Enum.filter(Ssm.Activity.list(), &(&1.action == "delete"))
    assert length(deletes) == 2
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
