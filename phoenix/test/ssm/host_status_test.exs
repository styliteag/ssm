defmodule Ssm.HostStatusTest do
  use ExUnit.Case, async: true

  alias Ssm.Diffs.HostCheck
  alias Ssm.HostStatus
  alias Ssm.Hosts.Host

  @enabled %Host{id: 1, disabled: false}
  @disabled %Host{id: 1, disabled: true}

  @auth_raw "ssh connect failed for web1: Unable to connect using the available authentication methods"
  @changed_raw "host key changed for web1: pinned ssh-ed25519 SHA256:a, offered ssh-ed25519 SHA256:b"
  @refused_raw "ssh connect failed for web1: econnrefused"

  defp check(attrs), do: struct(%HostCheck{host_id: 1, logins: 1, drift: []}, attrs)

  describe "derive/3" do
    drift = [%{"user" => "alice", "login" => "root", "missing" => ["a", "b"], "extra" => ["c"]}]

    cases = [
      {"disabled beats a cache entry", @disabled, {:synced, 0}, nil, :disabled},
      {"disabled beats a stored check", @disabled, nil, %{state: "synced"}, :disabled},
      {"nothing known is unchecked", @enabled, nil, nil, :unchecked},
      {"cached synced", @enabled, {:synced, 0}, nil, :synced},
      {"cached drift", @enabled, {{:needs_sync, 2, 1}, 0}, nil, {:drift, 2, 1}},
      {"cached auth failure", @enabled, {{:error, @auth_raw}, 0}, nil, {:auth_failed, @auth_raw}},
      {"cached host key change", @enabled, {{:error, @changed_raw}, 0}, nil,
       {:host_key_changed, @changed_raw}},
      {"cached other error", @enabled, {{:error, @refused_raw}, 0}, nil,
       {:unreachable, @refused_raw}},
      {"cache beats the stored check", @enabled, {:synced, 0}, %{state: "error"}, :synced},
      {"stored synced after a restart", @enabled, nil, %{state: "synced"}, :synced},
      {"stored drift counts missing and extra", @enabled, nil, %{state: "drift", drift: drift},
       {:drift, 2, 1}},
      {"stored auth failure", @enabled, nil,
       %{state: "error", error_code: "auth_failed", error: "auth sentence"},
       {:auth_failed, "auth sentence"}},
      {"stored host key change", @enabled, nil,
       %{state: "error", error_code: "host_key_changed", error: "key sentence"},
       {:host_key_changed, "key sentence"}},
      {"stored other error", @enabled, nil,
       %{state: "error", error_code: "timeout", error: "timed out"}, {:unreachable, "timed out"}},
      {"stored error without text", @enabled, nil, %{state: "error"}, {:unreachable, "error"}}
    ]

    for {name, host, cached, stored, expected} <- cases do
      @tag case: {host, cached, stored, expected}
      test name, %{case: {host, cached, stored, expected}} do
        stored = if stored, do: check(stored)
        assert HostStatus.derive(host, cached, stored) == expected
      end
    end
  end

  describe "from_connection/1" do
    test "a successful connect is reachable" do
      assert HostStatus.from_connection(:ok) == :reachable
    end

    test "a failed connect is classified from its message" do
      assert HostStatus.from_connection({:error, {:ssh_connect_failed, @auth_raw}}) ==
               {:auth_failed, @auth_raw}

      assert HostStatus.from_connection({:error, {:ssh_connect_failed, @changed_raw}}) ==
               {:host_key_changed, @changed_raw}

      assert HostStatus.from_connection({:error, :nxdomain}) == {:unreachable, ":nxdomain"}
    end
  end

  describe "predicates" do
    test "error?/1 and reachable?/1" do
      for s <- [{:auth_failed, "x"}, {:host_key_changed, "x"}, {:unreachable, "x"}] do
        assert HostStatus.error?(s)
        refute HostStatus.reachable?(s)
      end

      for s <- [:synced, {:drift, 1, 0}, :reachable] do
        assert HostStatus.reachable?(s)
        refute HostStatus.error?(s)
      end

      for s <- [:unchecked, :disabled] do
        refute HostStatus.reachable?(s)
        refute HostStatus.error?(s)
      end
    end
  end
end
