defmodule Ssm.Ssh.HostKeyCbTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.HostKeyCb

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"
  @ed25519_fp "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"
  @other_fp "ecdsa-sha2-nistp256 SHA256:lF0rWjfoTUXjkp9k51UM1vcqsjpqOz9XcMLrCCVpnNM"

  defp erlang_key do
    [{key, _}] = :ssh_file.decode(@ed25519, :openssh_key)
    key
  end

  defp opts(mode), do: [key_cb_private: [mode: mode, reply_to: self()]]

  test "verify mode accepts the pinned key and reports it" do
    assert HostKeyCb.is_host_key(
             erlang_key(),
             ~c"h",
             22,
             :"ssh-ed25519",
             opts({:verify, @ed25519_fp})
           )

    assert_received {:ssm_host_key, :accepted, %{fingerprint: @ed25519_fp}}
  end

  test "verify mode refuses another key and reports what was offered" do
    refute HostKeyCb.is_host_key(
             erlang_key(),
             ~c"h",
             22,
             :"ssh-ed25519",
             opts({:verify, @other_fp})
           )

    assert_received {:ssm_host_key, :rejected, %{fingerprint: @ed25519_fp, public_key: @ed25519}}
  end

  test "verify mode with a blank pin refuses (fail closed)" do
    refute HostKeyCb.is_host_key(erlang_key(), ~c"h", 22, :"ssh-ed25519", opts({:verify, nil}))
  end

  test "capture mode (probe only) accepts and reports the key" do
    assert HostKeyCb.is_host_key(erlang_key(), ~c"h", 22, :"ssh-ed25519", opts(:capture))
    assert_received {:ssm_host_key, :accepted, %{public_key: @ed25519}}
  end

  test "an unknown mode refuses" do
    refute HostKeyCb.is_host_key(erlang_key(), ~c"h", 22, :"ssh-ed25519", opts(:whatever))
  end

  test "add_host_key never persists anything" do
    assert HostKeyCb.add_host_key(~c"h", 22, erlang_key(), []) == :ok
  end
end
