defmodule Ssm.Diffs.HostChecksTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.{HostCheck, HostChecks, StatusCache}
  alias Ssm.Hosts
  alias Ssm.Repo
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup do
    start_supervised!(MockClient)
    StatusCache.reset()
    :ok
  end

  defp stub_version(host_id) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})
  end

  defp remote_keyfile(host_id, login, keyfile) do
    stub_version(host_id)

    MockClient.set_exec(host_id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout:
        Jason.encode!([
          %{login: login, has_pragma: true, readonly_condition: nil, keyfile: keyfile}
        ])
    })
  end

  defp authorized_host(key_base64 \\ "AAAAKEY1") do
    user = user_fixture(%{username: "alice"})
    host = host_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: key_base64, name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy"})
    host
  end

  describe "check_host/2" do
    test "in sync is stored as synced and fed to the status cache" do
      host = authorized_host()
      remote_keyfile(host.id, "deploy", "ssh-ed25519 AAAAKEY1 laptop")

      assert {:ok, %HostCheck{state: "synced", logins: 1, drift: []} = row} =
               HostChecks.check_host(host.id, client: MockClient)

      assert row.checked_at && row.changed_at
      assert %HostCheck{state: "synced"} = Repo.get!(HostCheck, host.id)
      assert {:synced, _at} = StatusCache.all()[host.id]
    end

    test "drift is stored per user without key material" do
      host = authorized_host()
      remote_keyfile(host.id, "deploy", "ssh-rsa AAAAOTHER stranger")

      assert {:ok, %HostCheck{state: "drift", drift: entries}} =
               HostChecks.check_host(host.id, client: MockClient)

      assert Enum.any?(entries, &(&1["user"] == "alice" and length(&1["missing"]) == 1))
      assert Enum.any?(entries, &(&1["user"] == nil and length(&1["extra"]) == 1))
      refute Jason.encode!(entries) =~ "AAAAKEY1"
      assert {{:needs_sync, 1, 1}, _} = StatusCache.all()[host.id]
    end

    test "an unreachable host is an error row with a fixed sentence" do
      host = authorized_host()
      MockClient.fail_connect(host.id)

      assert {:ok, %HostCheck{state: "error", error: error, error_code: code}} =
               HostChecks.check_host(host.id, client: MockClient)

      assert is_binary(error) and is_binary(code)
      assert {{:error, _raw}, _} = StatusCache.all()[host.id]
    end

    test "a disabled host is refused and keeps no row" do
      host = authorized_host()
      {:ok, _} = Hosts.update_host(host, %{disabled: true})

      assert {:error, :disabled} = HostChecks.check_host(host.id, client: MockClient)
      assert Repo.get(HostCheck, host.id) == nil
    end

    test "disabling a host drops its stale row" do
      host = authorized_host()
      remote_keyfile(host.id, "deploy", "ssh-ed25519 AAAAKEY1 laptop")
      {:ok, _} = HostChecks.check_host(host.id, client: MockClient)
      {:ok, _} = Hosts.update_host(host, %{disabled: true})

      assert {:error, :disabled} = HostChecks.check_host(host.id, client: MockClient)
      assert Repo.get(HostCheck, host.id) == nil
    end

    test "an unknown host is not_found" do
      assert {:error, :not_found} = HostChecks.check_host(999_999, client: MockClient)
    end

    test "the same result again moves checked_at but not changed_at; a new result moves both" do
      host = authorized_host()
      remote_keyfile(host.id, "deploy", "ssh-ed25519 AAAAKEY1 laptop")

      {:ok, first} =
        HostChecks.check_host(host.id, client: MockClient, now: ~U[2026-11-06 10:00:00Z])

      {:ok, same} =
        HostChecks.check_host(host.id, client: MockClient, now: ~U[2026-11-06 10:15:00Z])

      assert same.checked_at == ~U[2026-11-06 10:15:00Z]
      assert same.changed_at == first.changed_at

      remote_keyfile(host.id, "deploy", "ssh-rsa AAAAOTHER stranger")

      {:ok, drift} =
        HostChecks.check_host(host.id, client: MockClient, now: ~U[2026-11-06 10:30:00Z])

      assert drift.state == "drift"
      assert drift.changed_at == ~U[2026-11-06 10:30:00Z]
    end

    test "deleting the host deletes its row" do
      host = authorized_host()
      remote_keyfile(host.id, "deploy", "ssh-ed25519 AAAAKEY1 laptop")
      {:ok, _} = HostChecks.check_host(host.id, client: MockClient)

      {:ok, _} = Hosts.delete_host(host)
      assert Repo.get(HostCheck, host.id) == nil
    end
  end

  describe "sweep/1" do
    test "checks every enabled host, skips disabled, reports counts" do
      a = host_fixture()
      b = host_fixture()
      off = host_fixture()
      {:ok, _} = Hosts.update_host(off, %{disabled: true})
      me = self()

      result =
        HostChecks.sweep(
          check_fun: fn id ->
            send(me, {:checked, id})
            if id == b.id, do: {:error, :boom}, else: {:ok, %HostCheck{state: "synced"}}
          end
        )

      assert %{checked: 1, failed: 1} = result
      assert_received {:checked, id1}
      assert_received {:checked, id2}
      assert Enum.sort([id1, id2]) == Enum.sort([a.id, b.id])
      refute_received {:checked, _}
    end

    test "never runs more checks at once than the concurrency bound" do
      for _ <- 1..6, do: host_fixture()
      running = :atomics.new(1, [])
      me = self()

      HostChecks.sweep(
        concurrency: 2,
        check_fun: fn _id ->
          send(me, {:running, :atomics.add_get(running, 1, 1)})
          Process.sleep(20)
          :atomics.sub(running, 1, 1)
          {:ok, %HostCheck{}}
        end
      )

      seen =
        for _ <- 1..6,
            do:
              (receive do
                 {:running, n} -> n
               end)

      assert Enum.max(seen) <= 2
      assert Enum.max(seen) >= 1
    end

    @tag :capture_log
    test "a crashing or hanging check does not stop the sweep" do
      a = host_fixture()
      _b = host_fixture()

      result =
        HostChecks.sweep(
          timeout: 100,
          check_fun: fn id ->
            if id == a.id, do: Process.sleep(1_000), else: raise("boom")
          end
        )

      assert %{checked: 0, failed: 2} = result
    end
  end
end
