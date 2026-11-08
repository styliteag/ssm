defmodule Ssm.Hosts.PinStateTest do
  use ExUnit.Case, async: true

  alias Ssm.Hosts.Host
  alias Ssm.Hosts.PinState

  @fp "ssh-ed25519 SHA256:abc"
  @key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7"

  for {name, fingerprint, host_key, expected} <- [
        {"no fingerprint", nil, nil, :unpinned},
        {"blank fingerprint", "  ", nil, :unpinned},
        {"a stray key without fingerprint", nil, @key, :unpinned},
        {"pre-seeded fingerprint, no key yet", @fp, nil, :preseeded},
        {"pre-seeded fingerprint, blank key", @fp, "", :preseeded},
        {"fingerprint and key from a probe", @fp, @key, :confirmed}
      ] do
    @tag case: {fingerprint, host_key, expected}
    test "of/1: #{name}", %{case: {fingerprint, host_key, expected}} do
      assert PinState.of(%Host{key_fingerprint: fingerprint, host_key: host_key}) == expected
    end
  end

  test "every state has a tooltip naming the fingerprint when there is one" do
    assert PinState.title(%Host{key_fingerprint: nil}) =~ "No host key pinned"
    assert PinState.title(%Host{key_fingerprint: @fp}) =~ "not confirmed"
    assert PinState.title(%Host{key_fingerprint: @fp}) =~ @fp
    assert PinState.title(%Host{key_fingerprint: @fp, host_key: @key}) =~ "confirmed"
    assert PinState.title(%Host{key_fingerprint: @fp, host_key: @key}) =~ @fp
  end
end
