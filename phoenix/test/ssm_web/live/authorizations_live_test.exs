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

  test "renders grants whose user or host row is gone instead of crashing", %{conn: conn} do
    user = user_fixture(%{username: "alice"})
    host = host_fixture(%{name: "web1"})
    auth = authorization_fixture(user, host, %{login: "root"})

    # Legacy Diesel-era DBs contain orphaned grants (host deleted while FK
    # enforcement was off). defer_foreign_keys pushes the FK check past the
    # sandbox rollback so we can recreate that shape here.
    Ssm.Repo.query!("PRAGMA defer_foreign_keys = ON")
    Ssm.Repo.query!(~s(UPDATE "authorization" SET host_id = 999999 WHERE id = ?), [auth.id])

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    assert has_element?(view, "#authorizations-#{auth.id}", "alice")
    assert has_element?(view, "#authorizations-#{auth.id}", "missing host #999999")
  end

  test "list sorts by clicked column and search narrows rows", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    host = host_fixture(%{name: "web1"})
    alice_auth = authorization_fixture(alice, host, %{login: "zeta"})
    bob_auth = authorization_fixture(bob, host, %{login: "alpha"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    # id order: zeta first. Sort by login asc: alpha first, desc flips.
    assert render(view) =~ ~r/zeta.*alpha/s
    view |> element("th button", "Login") |> render_click()
    assert render(view) =~ ~r/alpha.*zeta/s
    view |> element("th button", "Login") |> render_click()
    assert render(view) =~ ~r/zeta.*alpha/s

    view |> element("#authorizations-search") |> render_change(%{q: "alice"})
    assert has_element?(view, "#authorizations-#{alice_auth.id}")
    refute has_element?(view, "#authorizations-#{bob_auth.id}")
  end

  test "matrix searches narrow users and hosts", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    web = host_fixture(%{name: "web1"})
    db = host_fixture(%{name: "db1"})
    authorization_fixture(alice, web, %{login: "root"})
    authorization_fixture(bob, db, %{login: "root"})

    {:ok, view, _html} = live(conn, ~p"/authorizations?view=matrix")

    view |> element("#matrix-user-search-form") |> render_change(%{q: "ali"})
    assert has_element?(view, "#matrix-row-#{alice.id}")
    refute has_element?(view, "#matrix-row-#{bob.id}")

    view |> element("#matrix-host-search-form") |> render_change(%{q: "db"})
    assert has_element?(view, "#matrix-cell-#{alice.id}-#{db.id}")
    refute has_element?(view, "#matrix-cell-#{alice.id}-#{web.id}")
  end

  test "bulk grant creates the cross product and skips existing grants", %{conn: conn} do
    u1 = user_fixture(%{username: "alice"})
    u2 = user_fixture(%{username: "bob"})
    h1 = host_fixture(%{name: "web1"})
    h2 = host_fixture(%{name: "web2"})
    _existing = authorization_fixture(u1, h1, %{login: "root"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#bulk-grant") |> render_click()

    for user <- [u1, u2], do: view |> element("#bulk-user-#{user.id}") |> render_click()
    for host <- [h1, h2], do: view |> element("#bulk-host-#{host.id}") |> render_click()

    view
    |> element("#bulk-grant-form")
    |> render_change(%{bulk: %{login: "root", options: "no-pty"}})

    assert has_element?(view, "#bulk-preview", "3 new grant(s)")
    assert has_element?(view, "#bulk-preview", "1 already exist")

    view |> element("#bulk-grant-form") |> render_submit()

    assert Ssm.Authorizations.count_authorizations() == 4
    assert Ssm.Authorizations.exists?(u2.id, h2.id, "root")

    assert Enum.any?(
             Ssm.Activity.list(),
             &(&1.action == "bulk_grant" and &1.activity_type == "auth")
           )
  end

  test "bulk grant search narrows the user and host lists", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    web = host_fixture(%{name: "web1"})
    db = host_fixture(%{name: "db1"})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#bulk-grant") |> render_click()

    view |> element("#bulk-user-search") |> render_change(%{q: "ali"})
    assert has_element?(view, "#bulk-user-#{alice.id}")
    refute has_element?(view, "#bulk-user-#{bob.id}")

    view |> element("#bulk-host-search") |> render_change(%{q: "db"})
    assert has_element?(view, "#bulk-host-#{db.id}")
    refute has_element?(view, "#bulk-host-#{web.id}")

    # Selection survives filtering: select filtered-in, clear filter, still selected.
    view |> element("#bulk-user-#{alice.id}") |> render_click()
    view |> element("#bulk-user-search") |> render_change(%{q: ""})
    assert has_element?(view, "#bulk-user-#{alice.id}[checked]")
  end

  test "bulk grant hides disabled users from the selection list", %{conn: conn} do
    _enabled = user_fixture(%{username: "on"})
    {:ok, disabled} = Ssm.Users.create_user(%{username: "off", enabled: false})

    {:ok, view, _html} = live(conn, ~p"/authorizations")

    view |> element("#bulk-grant") |> render_click()

    assert has_element?(view, "#bulk-grant-modal", "on")
    refute has_element?(view, "#bulk-user-#{disabled.id}")
  end

  describe "matrix view" do
    test "defaults to root, sorts logins by usage, hides hosts without the login", %{conn: conn} do
      alice = user_fixture(%{username: "alice"})
      bob = user_fixture(%{username: "bob"})
      web = host_fixture(%{name: "web1"})
      db = host_fixture(%{name: "db1"})

      authorization_fixture(alice, web, %{login: "deploy"})
      authorization_fixture(bob, web, %{login: "deploy"})
      authorization_fixture(alice, db, %{login: "root"})

      {:ok, view, _html} = live(conn, ~p"/authorizations?view=matrix")

      selector = view |> element("#matrix-login-form select") |> render()
      assert selector =~ "deploy (2)"
      assert selector =~ "root (1)"
      assert selector =~ ~s(<option selected="" value="root">)

      # root grants exist only on db1 — web1 is not a column.
      assert has_element?(view, "#matrix-cell-#{alice.id}-#{db.id}.btn-success")
      refute has_element?(view, "#matrix-cell-#{alice.id}-#{web.id}")
    end

    test "cell click grants and revokes under the selected login", %{conn: conn} do
      alice = user_fixture(%{username: "alice"})
      host = host_fixture(%{name: "web1"})
      bob = user_fixture(%{username: "bob"})
      authorization_fixture(bob, host, %{login: "deploy"})

      {:ok, view, _html} = live(conn, ~p"/authorizations?view=matrix&login=deploy")

      view |> element("#matrix-cell-#{alice.id}-#{host.id}") |> render_click()
      assert Ssm.Authorizations.exists?(alice.id, host.id, "deploy")

      view |> element("#matrix-cell-#{alice.id}-#{host.id}") |> render_click()
      refute Ssm.Authorizations.exists?(alice.id, host.id, "deploy")

      actions = Enum.map(Ssm.Activity.list(), & &1.action)
      assert "create" in actions
      assert "delete" in actions
    end

    test "the all login is view-only counts", %{conn: conn} do
      alice = user_fixture(%{username: "alice"})
      host = host_fixture(%{name: "web1"})
      authorization_fixture(alice, host, %{login: "root"})
      authorization_fixture(alice, host, %{login: "deploy"})

      {:ok, view, _html} = live(conn, ~p"/authorizations?view=matrix&login=all")

      assert has_element?(view, "span#matrix-cell-#{alice.id}-#{host.id}", "2")
      refute has_element?(view, "button#matrix-cell-#{alice.id}-#{host.id}")
    end

    test "show authorized only hides users without a grant", %{conn: conn} do
      alice = user_fixture(%{username: "alice"})
      idle = user_fixture(%{username: "idle"})
      host = host_fixture(%{name: "web1"})
      authorization_fixture(alice, host, %{login: "root"})

      {:ok, view, _html} = live(conn, ~p"/authorizations?view=matrix&login=root")

      assert has_element?(view, "#matrix-row-#{idle.id}")

      view |> element("#matrix-authorized-toggle") |> render_click()

      assert has_element?(view, "#matrix-row-#{alice.id}")
      refute has_element?(view, "#matrix-row-#{idle.id}")
    end
  end

  test "stats view shows totals and access rankings", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    {:ok, off} = Ssm.Users.create_user(%{username: "off", enabled: false})
    web = host_fixture(%{name: "web1"})
    db = host_fixture(%{name: "db1"})

    authorization_fixture(alice, web, %{login: "root"})
    authorization_fixture(bob, web, %{login: "root"})
    authorization_fixture(alice, db, %{login: "deploy"})
    authorization_fixture(off, db, %{login: "root"})

    {:ok, view, _html} = live(conn, ~p"/authorizations?view=stats")

    assert has_element?(view, "#stat-auth-total", "4")
    assert has_element?(view, "#stat-auth-active", "3")
    assert has_element?(view, "#stat-auth-inactive", "1")
    assert has_element?(view, "#stat-auth-logins", "2")

    assert has_element?(view, "#auth-stats", "web1")
    assert has_element?(view, "#auth-stats", "2 user(s)")
    assert has_element?(view, "#auth-stats", "2 host(s)")
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
