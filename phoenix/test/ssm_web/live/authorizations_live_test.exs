defmodule SsmWeb.AuthorizationsLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Authorizations

  setup [:setup_htpasswd, :log_in]

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/authorizations")
  end

  test "lists authorizations with user, host, and login", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    host = host_fixture(%{name: "web1"})
    auth = authorization_fixture(user, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    assert has_element?(view, "#authorizations-#{auth.id}", "alice")
    assert has_element?(view, "#authorizations-#{auth.id}", "web1")
    assert has_element?(view, "#authorizations-#{auth.id}", "deploy")
  end

  test "filters by host via query param", %{conn: conn} do
    user = user_fixture()
    host_a = host_fixture(%{name: "a"})
    host_b = host_fixture(%{name: "b"})
    auth_a = authorization_fixture(user, host_a)
    auth_b = authorization_fixture(user, host_b)

    {:ok, view, _html} = live(conn, ~p"/authorizations?host_id=#{host_a.id}")

    assert has_element?(view, "#authorizations-#{auth_a.id}")
    refute has_element?(view, "#authorizations-#{auth_b.id}")
  end

  test "creates an authorization through the modal and logs it", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    host = host_fixture(%{name: "web1"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#new-authorization") |> render_click()

    view
    |> form("#authorization-form",
      authorization: %{user_id: user.id, host_id: host.id, login: "deploy"}
    )
    |> render_submit()

    assert has_element?(view, "#authorizations", "deploy")
    assert [_] = Authorizations.list_authorizations(host_id: host.id)

    assert [entry] = Ssm.Activity.list()
    assert entry.activity_type == "auth"
    assert entry.action == "create"
    assert entry.target == "alice@web1:deploy"
  end

  test "rejects a duplicate (user, host, login) grant", %{conn: conn} do
    user = user_fixture()
    host = host_fixture()
    _ = authorization_fixture(user, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#new-authorization") |> render_click()

    html =
      view
      |> form("#authorization-form",
        authorization: %{user_id: user.id, host_id: host.id, login: "deploy"}
      )
      |> render_submit()

    assert html =~ "has already been taken"
    assert Authorizations.count_authorizations() == 1
  end

  test "edits an authorization", %{conn: conn} do
    user = user_fixture()
    host = host_fixture()
    auth = authorization_fixture(user, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#edit-authorization-#{auth.id}") |> render_click()

    view
    |> form("#authorization-form", authorization: %{login: "root", comment: "temp"})
    |> render_submit()

    updated = Authorizations.get_authorization(auth.id)
    assert updated.login == "root"
    assert updated.comment == "temp"
  end

  test "deletes an authorization", %{conn: conn} do
    user = user_fixture()
    host = host_fixture()
    auth = authorization_fixture(user, host)

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#delete-authorization-#{auth.id}") |> render_click()

    refute has_element?(view, "#authorizations-#{auth.id}")
    assert Authorizations.get_authorization(auth.id) == nil
  end
end
