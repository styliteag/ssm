defmodule Ssm.Diffs.RevocationCleanReadTest do
  @moduledoc """
  "Revocation pending" also ends on a read (diff, refresh, periodic check)
  that proves nothing revoked is left: no unauthorized line on any login,
  every login readable. Nothing is written to the host. A login that could
  not be read, or a line that is still there, keeps the mark.
  """
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs
  alias Ssm.Diffs.Revocations
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp stub_host(host, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})
    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
  end

  defp setup_host do
    host = host_fixture(%{username: "ssm-admin"})
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "KEEP", name: "k"})
    authorization_fixture(user, host, %{login: "deploy"})
    :ok = Revocations.mark(host.id, "authorization deleted")
    host
  end

  test "a clean read clears the mark and writes nothing" do
    host = setup_host()
    stub_host(host, [%{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 KEEP k"}])

    assert {:ok, _diff} = Diffs.host_diff(host.id)
    refute Revocations.pending?(host.id)
    refute Enum.any?(MockClient.calls().exec, &(inspect(&1) =~ "set_authorized_keyfile"))
  end

  test "an unauthorized line still on the host keeps the mark" do
    host = setup_host()

    stub_host(host, [
      %{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 KEEP k\nssh-ed25519 GONE old"}
    ])

    assert {:ok, _diff} = Diffs.host_diff(host.id)
    assert Revocations.pending?(host.id)
  end

  test "a home that does not exist (HA standby) does not keep the mark" do
    host = setup_host()

    stub_host(host, [
      %{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 KEEP k"},
      %{login: "other", has_pragma: false, home_state: "home_missing", keyfile: ""}
    ])

    assert {:ok, _diff} = Diffs.host_diff(host.id)
    refute Revocations.pending?(host.id)
  end

  for state <- ["home_unreadable", "unknown_login"] do
    test "#{state} keeps the mark" do
      host = setup_host()

      stub_host(host, [
        %{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 KEEP k"},
        %{login: "other", has_pragma: false, home_state: unquote(state), keyfile: ""}
      ])

      assert {:ok, _diff} = Diffs.host_diff(host.id)
      assert Revocations.pending?(host.id)
    end
  end

  test "a mark made while the host was read stays" do
    host = setup_host()
    stub_host(host, [%{login: "deploy", has_pragma: true, keyfile: "ssh-ed25519 KEEP k"}])
    # the mark is newer than the one the read saw
    seen = Revocations.seen(host.id)
    :ok = Revocations.clear(host.id, seen)
    :ok = Revocations.mark(host.id, "later")
    later = Revocations.seen(host.id)
    :ok = Revocations.clear(host.id, DateTime.add(later, -60))
    assert Revocations.pending?(host.id)
  end

  test "a disabled host's mark is kept but not listed or counted" do
    host = setup_host()
    assert Map.has_key?(Revocations.pending(Ssm.Scope.global()), host.id)
    {:ok, _} = Ssm.Hosts.update_host(host, %{disabled: true})

    refute Map.has_key?(Revocations.pending(Ssm.Scope.global()), host.id)
    assert Revocations.count(Ssm.Scope.global()) == 0
    assert Revocations.pending?(host.id)
  end
end
