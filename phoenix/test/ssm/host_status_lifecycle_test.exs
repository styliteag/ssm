defmodule Ssm.HostStatusLifecycleTest do
  # Deleting or disabling a host drops its last known status (status cache
  # and stored check), whichever path does it: UI, /api/v2, mctl.
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.{HostCheck, StatusCache}
  alias Ssm.Hosts
  alias Ssm.Repo

  setup do
    StatusCache.reset()
    :ok
  end

  defp seed_status(host) do
    StatusCache.put(host.id, :synced)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert!(%HostCheck{
      host_id: host.id,
      state: "synced",
      logins: 1,
      drift: [],
      checked_at: now,
      changed_at: now
    })
  end

  defp cached?(host), do: Map.has_key?(StatusCache.all(), host.id)
  defp stored?(host), do: Repo.get(HostCheck, host.id) != nil

  test "delete_host/1 (API, mctl) evicts the cache entry" do
    host = host_fixture()
    seed_status(host)

    assert {:ok, _} = Hosts.delete_host(host)
    refute cached?(host)
    refute stored?(host)
  end

  test "delete_host/2 (web UI) evicts the cache entry" do
    host = host_fixture()
    seed_status(host)

    assert {:ok, _} = Hosts.delete_host(Ssm.Scope.global(), host)
    refute cached?(host)
  end

  test "deleting a jump host evicts the hosts the cascade takes with it" do
    jump = host_fixture()
    behind = host_fixture(%{jump_via: jump.id})
    further = host_fixture(%{jump_via: behind.id})
    Enum.each([jump, behind, further], &seed_status/1)

    assert {:ok, _} = Hosts.delete_host(jump)
    refute Enum.any?([jump, behind, further], &cached?/1)
  end

  test "a failed delete keeps the status" do
    jump = host_fixture()
    _behind = host_fixture(%{jump_via: jump.id})
    seed_status(jump)

    assert {:error, {:jump_host_in_use, _}} = Hosts.delete_host(Ssm.Scope.global(), jump)
    assert cached?(jump)
  end

  test "disabling a host forgets its status, so re-enabling starts unchecked" do
    host = host_fixture()
    seed_status(host)

    assert {:ok, disabled} = Hosts.update_host(host, %{disabled: true})
    refute cached?(host)
    refute stored?(host)

    assert {:ok, _} = Hosts.update_host(disabled, %{disabled: false})
    refute cached?(host)
  end

  test "re-enabling forgets a status left over from before" do
    host = host_fixture()
    {:ok, host} = Hosts.update_host(host, %{disabled: true})
    seed_status(host)

    assert {:ok, _} = Hosts.update_host(host, %{disabled: false})
    refute cached?(host)
    refute stored?(host)
  end

  test "an edit that does not toggle disabled keeps the status" do
    host = host_fixture()
    seed_status(host)

    assert {:ok, _} = Hosts.update_host(host, %{comment: "rack 4"})
    assert cached?(host)
    assert stored?(host)
  end
end
