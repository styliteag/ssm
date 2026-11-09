defmodule SsmWeb.SharedComponentsTest do
  @moduledoc """
  Phase 3 of the UI plan: one styled confirm dialog, accessible modals,
  labelled icon buttons, empty states with an action, the sync list's
  search and filter in the URL.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Ssh.MockClient

  setup [:setup_htpasswd, :log_in]

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  test "every page carries the confirm dialog that replaces window.confirm", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/hosts")

    assert html =~ ~s(id="confirm-dialog")
    assert html =~ ~s(id="confirm-dialog-ok")
  end

  test "a modal is a labelled dialog that keeps focus inside", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosts")

    view |> element("#new-host") |> render_click()

    assert has_element?(view, ~s(#host-modal-box[role="dialog"][aria-modal="true"]))
    assert has_element?(view, ~s(#host-modal-box[aria-labelledby="host-modal-title"]))
    assert has_element?(view, "#host-modal-title", "New host")
    refute has_element?(view, "#host-modal .modal-backdrop[phx-click]")
  end

  test "icon-only row actions have an accessible name", %{conn: conn} do
    host = host_fixture(%{name: "web1"})

    {:ok, view, _html} = live(conn, ~p"/hosts")

    for {id, label} <- [
          {"delete-host-#{host.id}", "Delete host"},
          {"edit-host-#{host.id}", "Edit host"},
          {"test-host-#{host.id}", "Test SSH connection"},
          {"toggle-host-#{host.id}", "Disable host"}
        ] do
      assert has_element?(view, ~s(##{id}[aria-label="#{label}"]))
    end
  end

  test "empty lists offer the first step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosts")
    assert has_element?(view, "#hosts-empty button", "New host")

    {:ok, view, _html} = live(conn, ~p"/users")
    assert has_element?(view, "#users-empty button", "New SSH user")
  end

  test "the sync list keeps search and filter in the URL", %{conn: conn} do
    host_fixture(%{name: "web1"})
    host_fixture(%{name: "db1"})

    {:ok, view, _html} = live(conn, ~p"/diff")

    view |> element("#diff-search") |> render_change(%{"q" => "web"})
    assert_patch(view, ~p"/diff?#{[q: "web"]}")

    {:ok, view, _html} = live(conn, ~p"/diff?#{[q: "web", filter: "unchecked"]}")
    assert has_element?(view, ~s(#diff-search input[value="web"]))
    assert has_element?(view, ~s(#diff-filter option[selected][value="unchecked"]))
  end
end
