defmodule SsmWeb.HostsLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Hosts
  alias Ssm.Ssh.MockClient

  setup [:setup_htpasswd, :log_in]

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/hosts")
  end

  test "lists hosts with status badge and jump host name", %{conn: conn} do
    bastion = host_fixture(%{name: "bastion"})
    host = host_fixture(%{name: "web1", jump_via: bastion.id})
    {:ok, _} = Hosts.update_host(host, %{disabled: true})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    assert has_element?(view, "#hosts-#{host.id}", "web1")
    assert has_element?(view, "#hosts-#{host.id}", "bastion")
    assert has_element?(view, "#hosts-#{host.id} .badge", "disabled")
    assert has_element?(view, "#hosts-#{bastion.id} .badge", "enabled")
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

  test "toggle_disabled flips the flag and logs it", %{conn: conn} do
    host = host_fixture(%{name: "web1"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

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

    test "reports success", %{conn: conn} do
      host = host_fixture(%{name: "web1"})

      {:ok, view, _html} = live(conn, ~p"/hosts")

      view |> element("#test-host-#{host.id}") |> render_click()
      render_async(view)

      assert render(view) =~ "Connection to web1 succeeded"
      assert MockClient.calls().connect == [host.id]
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

      view |> element("#test-host-#{host.id}") |> render_click()

      assert render(view) =~ "is disabled"
      assert MockClient.calls().connect == []
    end
  end
end
