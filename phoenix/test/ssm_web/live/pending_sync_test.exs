defmodule SsmWeb.PendingSyncTest do
  @moduledoc """
  A change that takes access away reaches a host only at its next sync.
  The header says on every page how many hosts wait for that sync
  ("revocation pending", `Ssm.Diffs.Revocations`) and links to them.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Diffs.Revocations

  setup [:setup_htpasswd, :log_in]

  test "no badge while nothing is pending", %{conn: conn} do
    host_fixture(%{name: "web1"})

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#pending-sync")
  end

  test "every page shows the count and links to the pending hosts", %{conn: conn} do
    web1 = host_fixture(%{name: "web1"})
    web2 = host_fixture(%{name: "web2"})
    host_fixture(%{name: "db1"})
    :ok = Revocations.mark(web1.id, "test")
    :ok = Revocations.mark(web2.id, "test")

    for path <- [~p"/dashboard", ~p"/users", ~p"/access", ~p"/diff"] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, ~s(#pending-sync[href="/hosts?filter=pending"]), "2")
      assert has_element?(view, "#pending-sync", "hosts pending sync")
    end
  end

  test "the count follows a revoke on the same page", %{conn: conn} do
    alice = user_fixture(%{username: "alice"})
    host = host_fixture(%{name: "web1"})
    authorization_fixture(alice, host, %{login: "deploy"})

    {:ok, view, _html} = live(conn, ~p"/access?view=matrix&login=deploy")
    refute has_element?(view, "#pending-sync")

    view |> element("#matrix-cell-#{alice.id}-#{host.id}") |> render_click()

    assert has_element?(view, "#pending-sync", "1 host pending sync")
  end

  test "the hosts page filters the pending hosts", %{conn: conn} do
    web1 = host_fixture(%{name: "web1"})
    db1 = host_fixture(%{name: "db1"})
    :ok = Revocations.mark(web1.id, "test")

    {:ok, view, _html} = live(conn, ~p"/hosts?filter=pending")

    assert has_element?(view, "#filter-pending", "Pending sync (1)")
    assert has_element?(view, "#hosts-#{web1.id}")
    refute has_element?(view, "#hosts-#{db1.id}")
  end
end
