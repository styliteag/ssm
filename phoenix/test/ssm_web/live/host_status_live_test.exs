defmodule SsmWeb.HostStatusLiveTest do
  # Both pages show the one status `Ssm.HostStatus.derive/3` gives.
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Diffs.{HostCheck, StatusCache}
  alias Ssm.Hosts
  alias Ssm.Repo

  setup [:setup_htpasswd, :log_in]

  setup do
    StatusCache.reset()
    :ok
  end

  @auth_raw "ssh connect failed for x: Unable to connect using the available authentication methods"

  defp store(host, attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert!(
      struct(
        %HostCheck{host_id: host.id, logins: 1, drift: [], checked_at: now, changed_at: now},
        attrs
      )
    )
  end

  describe "hosts page" do
    test "after a restart (empty cache) the badge follows the stored check", %{conn: conn} do
      synced = host_fixture(%{name: "synced"})
      denied = host_fixture(%{name: "denied"})
      rekeyed = host_fixture(%{name: "rekeyed"})
      dead = host_fixture(%{name: "dead"})
      store(synced, state: "synced")
      store(denied, state: "error", error_code: "auth_failed", error: "auth failed sentence")
      store(rekeyed, state: "error", error_code: "host_key_changed", error: "key sentence")
      store(dead, state: "error", error_code: "timeout", error: "timed out")

      {:ok, view, _html} = live(conn, ~p"/hosts")

      assert has_element?(view, "#hosts-#{synced.id} .badge", "online")
      assert has_element?(view, "#hosts-#{denied.id} .badge", "auth failed")
      assert has_element?(view, "#hosts-#{rekeyed.id} .badge", "host key changed")
      assert has_element?(view, "#hosts-#{dead.id} .badge", "offline")
      assert has_element?(view, "#filter-offline", "Offline (3)")
      assert has_element?(view, "#filter-unknown", "Unknown (0)")
    end

    test "a cached auth failure is named, not 'offline'", %{conn: conn} do
      host = host_fixture()
      StatusCache.put(host.id, {:error, @auth_raw})

      {:ok, view, _html} = live(conn, ~p"/hosts")
      assert has_element?(view, "#hosts-#{host.id} .badge", "auth failed")
    end

    test "disable and re-enable shows no stale status", %{conn: conn} do
      host = host_fixture()
      store(host, state: "synced")
      StatusCache.put(host.id, :synced)

      {:ok, view, _html} = live(conn, ~p"/hosts")
      assert has_element?(view, "#hosts-#{host.id} .badge", "online")

      view |> element("#toggle-host-#{host.id}") |> render_click()
      view |> element("#filter-all") |> render_click()
      assert has_element?(view, "#hosts-#{host.id} .badge", "disabled")

      view |> element("#toggle-host-#{host.id}") |> render_click()
      assert has_element?(view, "#hosts-#{host.id} .badge", "unknown")
    end

    test "a host deleted through the API does not leave its status to a reused id",
         %{conn: conn} do
      host = host_fixture()
      StatusCache.put(host.id, {:error, @auth_raw})
      {:ok, _} = Hosts.delete_host(host)

      refute Map.has_key?(StatusCache.all(), host.id)

      {:ok, view, _html} = live(conn, ~p"/hosts")
      refute has_element?(view, "#hosts-#{host.id}")
    end
  end

  describe "diff page" do
    test "names auth failures and host key changes", %{conn: conn} do
      denied = host_fixture(%{name: "denied"})
      rekeyed = host_fixture(%{name: "rekeyed"})
      store(denied, state: "error", error_code: "auth_failed", error: "auth failed sentence")
      store(rekeyed, state: "error", error_code: "host_key_changed", error: "key sentence")

      {:ok, view, _html} = live(conn, ~p"/diff")

      assert has_element?(view, "#diff-row-#{denied.id} .badge", "auth failed")
      assert has_element?(view, "#diff-row-#{rekeyed.id} .badge", "host key changed")
    end
  end

  describe "host key pin icon" do
    test "shows unpinned, pre-seeded and confirmed apart", %{conn: conn} do
      fp = "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"
      none = host_fixture(%{name: "none"})
      seeded = host_fixture(%{name: "seeded", key_fingerprint: fp})

      confirmed =
        host_fixture(%{name: "confirmed"})
        |> Ecto.Changeset.change(key_fingerprint: fp, host_key: "ssh-ed25519 AAAAKEY")
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/hosts")

      assert has_element?(view, "#hosts-#{none.id} [data-pin-state=unpinned]")
      assert has_element?(view, "#hosts-#{seeded.id} [data-pin-state=preseeded]")
      assert has_element?(view, "#hosts-#{confirmed.id} [data-pin-state=confirmed]")

      assert view |> element("#hosts-#{seeded.id} [data-pin-state]") |> render() =~
               "not confirmed"
    end
  end
end
