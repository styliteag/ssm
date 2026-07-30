defmodule SsmWeb.KeysLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Users

  setup [:setup_htpasswd, :log_in]

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/keys")
  end

  test "lists keys with owner and type badge", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    key = key_fixture(user, %{name: "laptop"})

    {:ok, view, _html} = live(conn, ~p"/keys")

    assert has_element?(view, "#keys-#{key.id}", "alice")
    assert has_element?(view, "#keys-#{key.id}", "laptop")
    assert has_element?(view, "#keys-#{key.id} .badge", "ssh-ed25519")
  end

  test "filters by user via query param", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    alice_key = key_fixture(alice)
    bob_key = key_fixture(bob)

    {:ok, view, _html} = live(conn, ~p"/keys?user_id=#{alice.id}")

    assert has_element?(view, "#keys-#{alice_key.id}")
    refute has_element?(view, "#keys-#{bob_key.id}")
  end

  test "creates a key through the modal and logs it", %{conn: conn} do
    user = user_fixture(%{username: "alice"})

    {:ok, view, _html} = live(conn, ~p"/keys")

    view |> element("#new-key") |> render_click()

    view
    |> form("#key-form",
      user_key: %{
        user_id: user.id,
        key_type: "ssh-ed25519",
        key_base64: "AAAAC3NzaC1lZDI1NTE5AAAAINEW",
        name: "new-laptop"
      }
    )
    |> render_submit()

    assert has_element?(view, "#keys", "new-laptop")
    assert [_] = Users.list_keys(user_id: user.id)

    assert [entry] = Ssm.Activity.list()
    assert entry.activity_type == "key"
    assert entry.action == "create"
    assert entry.target == "new-laptop"
  end

  test "rejects key material with a type prefix", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} = live(conn, ~p"/keys")

    view |> element("#new-key") |> render_click()

    html =
      view
      |> form("#key-form",
        user_key: %{
          user_id: user.id,
          key_type: "ssh-ed25519",
          key_base64: "ssh-ed25519 AAAA laptop"
        }
      )
      |> render_submit()

    assert html =~ "must be base64 key material"
    assert Users.count_keys() == 0
  end

  test "edits only name and comment", %{conn: conn} do
    user = user_fixture()
    key = key_fixture(user, %{name: "old"})

    {:ok, view, _html} = live(conn, ~p"/keys")

    view |> element("#edit-key-#{key.id}") |> render_click()

    view
    |> form("#key-form", user_key: %{name: "renamed", extra_comment: "note"})
    |> render_submit()

    updated = Users.get_key(key.id)
    assert updated.name == "renamed"
    assert updated.extra_comment == "note"
    assert updated.key_base64 == key.key_base64
  end

  test "view modal shows the full authorized_keys line", %{conn: conn} do
    user = user_fixture()
    key = key_fixture(user, %{name: "laptop", key_base64: "FULLKEYMATERIAL"})

    {:ok, view, _html} = live(conn, ~p"/keys")

    view |> element("#view-key-#{key.id}") |> render_click()

    assert has_element?(view, "#key-view-line", "ssh-ed25519 FULLKEYMATERIAL laptop")
  end

  test "deletes a key", %{conn: conn} do
    user = user_fixture()
    key = key_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/keys")

    view |> element("#delete-key-#{key.id}") |> render_click()

    refute has_element?(view, "#keys-#{key.id}")
    assert Users.get_key(key.id) == nil
  end
end
