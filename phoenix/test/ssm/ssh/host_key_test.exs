defmodule Ssm.Ssh.HostKeyTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.HostKey

  # Public host keys generated with ssh-keygen for this test; the expected
  # fingerprints are `ssh-keygen -lf` output for the same files.
  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ host@test"
  @ed25519_fp "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"
  @ecdsa "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFcTF9aipgeAMjSyElCBUTSHDTlKCt9j/Rda6GA9o9fdyrrRR0KyMQ4Le+pszUVoysgdLYBJvYZaTVlBPq/Gy4U= host@test"
  @ecdsa_fp "ecdsa-sha2-nistp256 SHA256:lF0rWjfoTUXjkp9k51UM1vcqsjpqOz9XcMLrCCVpnNM"

  describe "fingerprint/1" do
    test "matches ssh-keygen -lf for ed25519 and ecdsa" do
      assert HostKey.fingerprint(@ed25519) == {:ok, @ed25519_fp}
      assert HostKey.fingerprint(@ecdsa) == {:ok, @ecdsa_fp}
    end

    test "rejects garbage" do
      assert HostKey.fingerprint("not a key") == {:error, :invalid_public_key}
      assert HostKey.fingerprint("ssh-ed25519 !!!") == {:error, :invalid_public_key}
    end
  end

  describe "public_key/1" do
    test "drops the comment and normalises whitespace" do
      assert HostKey.public_key("  #{@ed25519}  ") ==
               {:ok, @ed25519 |> String.replace(" host@test", "")}
    end
  end

  describe "normalize_fingerprint/1" do
    test "accepts the pinned format, ssh-keygen -l output and a bare hash" do
      assert HostKey.normalize_fingerprint(@ed25519_fp) == {:ok, @ed25519_fp}

      assert HostKey.normalize_fingerprint(
               "256 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q host@test (ED25519)"
             ) == {:ok, @ed25519_fp}

      assert HostKey.normalize_fingerprint("SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q") ==
               {:ok, "SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"}
    end

    test "rejects MD5 and junk" do
      assert HostKey.normalize_fingerprint("MD5:aa:bb") == {:error, :invalid_fingerprint}
      assert HostKey.normalize_fingerprint("hello") == {:error, :invalid_fingerprint}
      assert HostKey.normalize_fingerprint("") == {:error, :invalid_fingerprint}
    end
  end

  describe "matches?/2" do
    test "same type and hash match" do
      assert HostKey.matches?(@ed25519_fp, @ed25519_fp)
    end

    test "a different hash never matches" do
      refute HostKey.matches?(@ed25519_fp, @ecdsa_fp)
    end

    test "a pinned bare hash matches the same hash of any type" do
      assert HostKey.matches?("SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q", @ed25519_fp)
    end

    test "same hash with a different declared type does not match" do
      refute HostKey.matches?(
               "ssh-rsa SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q",
               @ed25519_fp
             )
    end

    test "unpinned (nil/blank) never matches" do
      refute HostKey.matches?(nil, @ed25519_fp)
      refute HostKey.matches?("", @ed25519_fp)
    end
  end

  describe "pinned?/1" do
    test "blank values are unpinned" do
      refute HostKey.pinned?(nil)
      refute HostKey.pinned?("  ")
      assert HostKey.pinned?(@ed25519_fp)
    end
  end

  describe "known_hosts_line/3" do
    test "port 22 uses the bare address, other ports the bracket form" do
      {:ok, key} = HostKey.public_key(@ed25519)
      assert HostKey.known_hosts_line("10.0.0.1", 22, key) == "10.0.0.1 #{key}"
      assert HostKey.known_hosts_line("jump.example", 2222, key) == "[jump.example]:2222 #{key}"
    end
  end

  describe "algorithm_preference/1" do
    test "puts the pinned key type first, then the fixed order" do
      assert HostKey.algorithm_preference(@ecdsa_fp) |> List.first() == :"ecdsa-sha2-nistp256"

      assert HostKey.algorithm_preference("ssh-rsa SHA256:x") |> Enum.take(2) ==
               [:"rsa-sha2-512", :"rsa-sha2-256"]
    end

    test "unpinned or untyped uses the fixed order (ed25519, ECDSA, RSA)" do
      prefs = HostKey.algorithm_preference(nil)
      assert List.first(prefs) == :"ssh-ed25519"
      assert prefs == HostKey.algorithm_preference("SHA256:abc")

      assert Enum.find_index(prefs, &(&1 == :"ecdsa-sha2-nistp256")) <
               Enum.find_index(prefs, &(&1 == :"rsa-sha2-512"))

      assert prefs == Enum.uniq(prefs)
    end
  end

  describe "from_erlang_key/1" do
    test "encodes an Erlang public key to line + fingerprint" do
      [{key, _attrs}] = :ssh_file.decode(@ed25519, :openssh_key)

      assert HostKey.from_erlang_key(key) ==
               {:ok,
                %{
                  public_key: @ed25519 |> String.replace(" host@test", ""),
                  fingerprint: @ed25519_fp
                }}
    end
  end
end
