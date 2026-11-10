defmodule SsmWeb.HostsLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Hosts
  alias Ssm.Ssh.MockClient

  setup [:setup_htpasswd, :log_in]

  setup do
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/hosts")
  end

  test "a long host list shows 100 rows and a Show more button", %{conn: conn} do
    for n <- 1..120, do: host_fixture(%{name: "bulk#{String.pad_leading("#{n}", 3, "0")}"})

    {:ok, view, _html} = live(conn, ~p"/hosts")
    assert has_element?(view, "#hosts-position", "100 of 120")
    assert has_element?(view, "#hosts", "bulk001")
    refute has_element?(view, "#hosts", "bulk120")

    view |> element("#hosts-more") |> render_click()
    assert has_element?(view, "#hosts-position", "120 of 120")
    assert has_element?(view, "#hosts", "bulk120")
  end

  test "the column sort lives in the URL and survives a reload", %{conn: conn} do
    host_fixture(%{name: "b-host"})
    host_fixture(%{name: "a-host"})

    {:ok, view, _html} = live(conn, ~p"/hosts")
    view |> element(~s([phx-click="sort"][phx-value-key="name"])) |> render_click()
    assert_patch(view, ~p"/hosts?#{[sort: "name:asc"]}")

    {:ok, view, _html} = live(conn, ~p"/hosts?sort=name:desc")
    html = render(view)
    assert :binary.match(html, "b-host") < :binary.match(html, "a-host")

    # an unknown sort key or direction is ignored
    {:ok, view, _html} = live(conn, ~p"/hosts?sort=bogus:up")
    assert render(view) =~ "a-host"
  end

  test "lists hosts with status badge and jump host name", %{conn: conn} do
    bastion = host_fixture(%{name: "bastion"})
    host = host_fixture(%{name: "web1", jump_via: bastion.id})
    {:ok, _} = Hosts.update_host(host, %{disabled: true})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    # Default filter hides disabled hosts; "All" shows both.
    refute has_element?(view, "#hosts-#{host.id}")
    view |> element("#filter-all") |> render_click()

    assert has_element?(view, "#hosts-#{host.id}", "web1")
    assert has_element?(view, "#hosts-#{host.id}", "bastion")
    assert has_element?(view, "#hosts-#{host.id} .badge", "disabled")
    assert has_element?(view, "#hosts-#{bastion.id} .badge", "not checked")
  end

  test "a non-root login is marked limited with a hint, in list and cards", %{conn: conn} do
    root = host_fixture(%{name: "r1", username: "root"})
    deploy = host_fixture(%{name: "d1", username: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    assert has_element?(view, "#hosts-#{deploy.id} [data-limited]", "limited")
    refute has_element?(view, "#hosts-#{root.id} [data-limited]")

    assert view |> element("#hosts-#{deploy.id} [data-limited]") |> render() =~
             "only read and manage"

    view |> element("#hosts-view-cards") |> render_click()
    assert has_element?(view, "#host-card-#{deploy.id} [data-limited]")
    refute has_element?(view, "#host-card-#{root.id} [data-limited]")
  end

  test "status badge feeds from the diff status cache; filters narrow rows", %{conn: conn} do
    up = host_fixture(%{name: "up"})
    drifted = host_fixture(%{name: "drifted"})
    down = host_fixture(%{name: "down"})
    fresh = host_fixture(%{name: "fresh"})

    Ssm.Diffs.StatusCache.put(up.id, :synced)
    Ssm.Diffs.StatusCache.put(drifted.id, {:needs_sync, 1, 0})
    Ssm.Diffs.StatusCache.put(down.id, {:error, "boom"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    assert has_element?(view, "#hosts-#{up.id} .badge", "online")
    assert has_element?(view, "#hosts-#{drifted.id} .badge", "online")
    assert has_element?(view, "#hosts-#{down.id} .badge", "unreachable")
    assert has_element?(view, "#hosts-#{fresh.id} .badge", "not checked")

    assert has_element?(view, "#filter-online", "Online (2)")
    assert has_element?(view, "#filter-offline", "Unreachable (1)")

    view |> element("#filter-offline") |> render_click()
    assert has_element?(view, "#hosts-#{down.id}")
    refute has_element?(view, "#hosts-#{up.id}")
  end

  test "columns sort on click", %{conn: conn} do
    host_fixture(%{name: "zebra"})
    host_fixture(%{name: "alpha"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    assert render(view) =~ ~r/zebra.*alpha/s
    view |> element("th button", "Name") |> render_click()
    assert render(view) =~ ~r/alpha.*zebra/s
    view |> element("th button", "Name") |> render_click()
    assert render(view) =~ ~r/zebra.*alpha/s
  end

  test "cards view renders host cards with status and actions", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    Ssm.Diffs.StatusCache.put(host.id, :synced)

    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#hosts-view-cards") |> render_click()

    assert has_element?(view, "#host-card-#{host.id}", "web1")
    assert has_element?(view, "#host-card-#{host.id} .badge", "online")
    assert has_element?(view, "#host-card-#{host.id} #edit-host-#{host.id}")
    refute has_element?(view, "#hosts-#{host.id}")
  end

  test "rows cross-link to authorizations and the diff viewer", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    user = user_fixture()
    authorization_fixture(user, host, %{login: "root"})
    authorization_fixture(user, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    assert has_element?(
             view,
             "#hosts-#{host.id} a[href='/access?host_id=#{host.id}']",
             "2"
           )

    assert has_element?(view, "#diff-link-#{host.id}[href='/diff?host_id=#{host.id}']")
  end

  test "creates a host through the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#new-host") |> render_click()
    assert has_element?(view, "#host-form")

    view
    |> form("#host-form", host: %{name: "edge", address: "10.1.1.1", port: 22, username: "root"})
    |> render_submit()

    assert has_element?(view, "#hosts", "edge")
    assert [%{name: "edge"}] = Hosts.list_hosts()

    assert [entry] = Ssm.Activity.list()
    assert entry.activity_type == "host"
    assert entry.action == "create"
    assert entry.target == "edge"
    assert entry.actor_username == "admin"
  end

  test "shows validation errors without saving", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#new-host") |> render_click()

    html =
      view
      |> form("#host-form", host: %{name: "", address: "10.1.1.1", port: 22, username: "root"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Hosts.list_hosts() == []
  end

  test "edits a host and clears jump_via via the empty select value", %{conn: conn} do
    bastion = host_fixture(%{name: "bastion"})
    host = host_fixture(%{name: "web1", jump_via: bastion.id})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#edit-host-#{host.id}") |> render_click()

    view
    |> form("#host-form", host: %{name: "web1-renamed", jump_via: ""})
    |> render_submit()

    updated = Hosts.get_host(host.id)
    assert updated.name == "web1-renamed"
    assert updated.jump_via == nil
  end

  test "deletes a host", %{conn: conn} do
    host = host_fixture(%{name: "victim"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#delete-host-#{host.id}") |> render_click()

    refute has_element?(view, "#hosts-#{host.id}")
    assert Hosts.get_host(host.id) == nil
  end

  test "the delete question says the keys stay on the host", %{conn: conn} do
    host = host_fixture(%{name: "web1"})
    alice = user_fixture(%{username: "alice"})
    authorization_fixture(alice, host, %{login: "deploy"})
    authorization_fixture(alice, host, %{login: "root"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    confirm =
      view
      |> element("#delete-host-#{host.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-confirm")
      |> List.first("")

    assert confirm =~ "Delete host web1?"
    assert confirm =~ "2 access entries"
    assert confirm =~ "stay on the host"
    assert confirm =~ "ssm's own key"
  end

  test "toggle_disabled flips the flag and logs it", %{conn: conn} do
    host = host_fixture(%{name: "web1"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    # "All" keeps the row visible across the disable/enable round-trip.
    view |> element("#filter-all") |> render_click()

    view |> element("#toggle-host-#{host.id}") |> render_click()
    assert Hosts.get_host(host.id).disabled

    assert [entry] = Ssm.Activity.list()
    assert entry.action == "disable"

    view |> element("#toggle-host-#{host.id}") |> render_click()
    refute Hosts.get_host(host.id).disabled
  end

  describe "test_connection" do
    setup do
      start_supervised!(MockClient)
      :ok
    end

    test "reports success and flips the badge to online", %{conn: conn} do
      host = host_fixture(%{name: "web1"})

      {:ok, view, _html} = live(conn, ~p"/hosts")

      assert has_element?(view, "#hosts-#{host.id} .badge", "not checked")

      view |> element("#test-host-#{host.id}") |> render_click()
      render_async(view)

      assert render(view) =~ "Connection to web1 succeeded"
      assert MockClient.calls().connect == [host.id]
      assert has_element?(view, "#hosts-#{host.id} .badge", "online")
    end

    test "reports failure", %{conn: conn} do
      host = host_fixture(%{name: "web1"})
      MockClient.fail_connect(host.id)

      {:ok, view, _html} = live(conn, ~p"/hosts")

      view |> element("#test-host-#{host.id}") |> render_click()
      render_async(view)

      assert render(view) =~ "Connection to web1 failed"
    end

    test "refuses disabled hosts without touching SSH", %{conn: conn} do
      host = host_fixture(%{name: "web1"})
      {:ok, host} = Hosts.update_host(host, %{disabled: true})

      {:ok, view, _html} = live(conn, ~p"/hosts")

      view |> element("#filter-disabled") |> render_click()
      view |> element("#test-host-#{host.id}") |> render_click()

      assert render(view) =~ "is disabled"
      assert MockClient.calls().connect == []
    end
  end

  describe "refresh all" do
    setup do
      start_supervised!(MockClient)
      :ok
    end

    test "asks before it connects and names the number of hosts", %{conn: conn} do
      host_fixture(%{name: "web1"})
      host_fixture(%{name: "web2"})

      {:ok, view, _html} = live(conn, ~p"/hosts")

      button = element(view, "#refresh-all")
      assert render(button) =~ "Test connections (2)"
      assert render(button) =~ ~s(data-confirm="Refresh 2 hosts?)
      assert MockClient.calls().connect == []
    end

    test "tests every listed enabled host once and streams the results", %{conn: conn} do
      ok = host_fixture(%{name: "web1"})
      bad = host_fixture(%{name: "web2"})
      off = host_fixture(%{name: "web3"})
      {:ok, _} = Hosts.update_host(off, %{disabled: true})
      MockClient.fail_connect(bad.id)

      {:ok, view, _html} = live(conn, ~p"/hosts")
      # "All" lists the disabled host too: it is skipped all the same
      view |> element("#filter-all") |> render_click()
      assert render(element(view, "#refresh-all")) =~ "Test connections (2)"

      view |> element("#refresh-all") |> render_click()
      render_async(view)

      assert Enum.sort(MockClient.calls().connect) == Enum.sort([ok.id, bad.id])
      assert has_element?(view, "#hosts-#{ok.id} .badge", "online")
      assert has_element?(view, "#hosts-#{bad.id} .badge", "unreachable")
      assert has_element?(view, "#hosts-#{off.id} .badge", "disabled")
      assert has_element?(view, "#checked-#{ok.id}", "checked just now")
      assert render(view) =~ "Tested 2 hosts: 1 online, 1 unreachable"
    end

    test "only the hosts the filter lists", %{conn: conn} do
      up = host_fixture(%{name: "up"})
      other = host_fixture(%{name: "other"})
      Ssm.Diffs.StatusCache.put(up.id, :synced)

      {:ok, view, _html} = live(conn, ~p"/hosts")
      view |> element("#filter-online") |> render_click()
      view |> element("#refresh-all") |> render_click()
      render_async(view)

      assert MockClient.calls().connect == [up.id]
      refute other.id in MockClient.calls().connect
    end
  end

  describe "pin host keys now" do
    setup do
      start_supervised!(MockClient)
      :ok
    end

    @ed "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"

    test "pins unpinned hosts and reports failures", %{conn: conn} do
      ok = host_fixture(%{name: "web1"})
      bad = host_fixture(%{name: "web2"})
      MockClient.set_host_keys(ok.id, [@ed])
      MockClient.fail_connect(bad.id)

      {:ok, view, _html} = live(conn, ~p"/hosts")

      view |> element("#pin-host-keys") |> render_click()
      render_async(view)

      html = render(view)
      assert html =~ "Pinned 1 host key"
      assert html =~ "web2"
      assert Hosts.get_host(ok.id).key_fingerprint =~ "ssh-ed25519 SHA256:"
      assert Hosts.get_host(bad.id).key_fingerprint == nil
      assert has_element?(view, "#hosts-#{ok.id} [data-pinned]")
    end
  end
end
