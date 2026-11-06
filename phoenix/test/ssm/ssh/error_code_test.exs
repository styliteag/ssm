defmodule Ssm.Ssh.ErrorCodeTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.ErrorCode

  @cases [
    {"ssh connect failed for web1: :econnrefused", "connect_refused"},
    {"ssh connect failed for web1: :timeout", "timeout"},
    {"ssh connect failed for web1: {:forwarder_not_ready, {:listen_timeout, 4000}}", "timeout"},
    {"ssh connect failed for web1: :ehostunreach", "unreachable"},
    {"ssh connect failed for web1: :enetunreach", "unreachable"},
    {"ssh connect failed for web1: :nxdomain", "dns_error"},
    {"ssh connect failed for web1: ~c\"Unable to connect using the available authentication methods\"",
     "auth_failed"},
    {"host key changed for web1: pinned a, offered b — refusing", "host_key_changed"},
    {"host key for web1 is not pinned — refusing to connect unverified", "host_key_unpinned"},
    {"jump host j cannot be verified by OpenSSH: …", "host_key_unpinned"},
    {"host web1 has an invalid username for SSH — refusing", "invalid_host"},
    {"something else entirely", "connect_failed"}
  ]

  test "classify/1 maps SSH failure messages to short codes" do
    for {message, code} <- @cases do
      assert {^code, short} = ErrorCode.classify({:ssh_connect_failed, message}), message
      assert is_binary(short)
      refute short =~ "web1", "short text must not echo the raw detail"
    end
  end

  test "other reasons are connect_failed; a disabled host has its own code" do
    assert {"connect_failed", _} = ErrorCode.classify(:weird)
    assert {"host_disabled", _} = ErrorCode.classify({:host_disabled, "host \"x\" is disabled"})
  end
end
