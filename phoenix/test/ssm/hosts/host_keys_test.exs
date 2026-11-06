defmodule Ssm.Hosts.HostKeysTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.{Activity, Hosts}
  alias Ssm.Hosts.HostKeys
  alias Ssm.Ssh.MockClient

  @ed "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"
  @ed_fp "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"
  @ecdsa "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFcTF9aipgeAMjSyElCBUTSHDTlKCt9j/Rda6GA9o9fdyrrRR0KyMQ4Le+pszUVoysgdLYBJvYZaTVlBPq/Gy4U="
  @ecdsa_fp "ecdsa-sha2-nistp256 SHA256:lF0rWjfoTUXjkp9k51UM1vcqsjpqOz9XcMLrCCVpnNM"
  @rsa "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDCIrHBO+p4RDeJ+bXChAlUP295dLnKZxiV3I/w5XiasZBdE0PeLkYRFHlK7m65FCHuZCM/EtRN5kqX7pq6LGNun9pGlnfi0tYAsDQBePskOzwkGk7DcGq7yQhK8pxXhXbX5Ua6+HJPLFJ+6Kl+MBu+mKKV7PgrmFpt3HR6nKhARmg1pZQ8LMSNldHor3otdRUV8685jVfEimjf9sw92EqZN3wQsaU8aHH1kRqrdkLSWKiz6IAY1XabAvjsrrclmOQ1/HJaSsZ1FkxnndwXOa4lJaaJBWgtb04ZIQpnyzes8ehpKCx+3UAKulok2e5oS5w2/UY2p3Q27OJ7nBVHfakL"
  @rsa_hash "SHA256:wjbvYHHZdKD4ymD5HqB/uZNU6UpuHdfAWg/7ay4ez2s"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  describe "pin/2" do
    test "unpinned host: probes once (TOFU) and stores fingerprint + public key" do
      host = host_fixture()
      MockClient.set_host_keys(host.id, [@ed])

      assert {:ok, :pinned, pinned} = HostKeys.pin(host, actor: "admin")
      assert pinned.key_fingerprint == @ed_fp
      assert pinned.host_key == @ed
      assert Hosts.get_host(host.id).key_fingerprint == @ed_fp
      assert [{_, opts}] = MockClient.calls().probe
      assert opts[:expect] == nil

      assert [entry] = Activity.list(activity_type: "host")
      assert entry.action == "pin_host_key"
      assert entry.actor_username == "admin"
    end

    test "disabled host: refused before any SSH" do
      host = host_fixture(%{disabled: true})
      MockClient.set_host_keys(host.id, [@ed])

      assert {:error, {:host_disabled, _}} = HostKeys.pin(host)
      assert MockClient.calls().probe == []
      assert MockClient.calls().connect == []
    end

    test "fully pinned host: nothing to do, no SSH" do
      host = host_fixture(%{key_fingerprint: @ed_fp})
      {:ok, host} = HostKeys.store_key(host, %{public_key: @ed, fingerprint: @ed_fp})

      assert {:ok, :already_pinned, _} = HostKeys.pin(host)
      assert MockClient.calls().probe == []
    end

    test "pre-seeded fingerprint: verifies against it (never TOFU) and fills the public key" do
      host = host_fixture(%{key_fingerprint: @ecdsa_fp})
      MockClient.set_host_keys(host.id, [@ed, @ecdsa])

      assert {:ok, :verified, verified} = HostKeys.pin(host)
      assert verified.host_key == @ecdsa
      assert [{_, opts}] = MockClient.calls().probe
      assert opts[:expect] == @ecdsa_fp
      assert opts[:prefer] == "ecdsa-sha2-nistp256"
    end

    test "legacy bare SHA256 pin: finds the key type that matches and stores it typed" do
      host = host_fixture(%{key_fingerprint: @rsa_hash})
      MockClient.set_host_keys(host.id, [@ed, @rsa])

      assert {:ok, :verified, verified} = HostKeys.pin(host)
      assert verified.key_fingerprint == "ssh-rsa " <> @rsa_hash
      assert verified.host_key == @rsa
    end

    test "changed key: refused, DB untouched, both fingerprints reported" do
      host = host_fixture(%{key_fingerprint: @ecdsa_fp})
      MockClient.set_host_keys(host.id, [@ed])

      assert {:error, {:host_key_changed, %{pinned: @ecdsa_fp, offered: offered}}} =
               HostKeys.pin(host)

      assert offered.fingerprint == @ed_fp
      assert Hosts.get_host(host.id).key_fingerprint == @ecdsa_fp
      assert Hosts.get_host(host.id).host_key == nil
    end

    test "connect failure is passed through" do
      host = host_fixture()
      MockClient.fail_connect(host.id)

      assert {:error, {:ssh_connect_failed, _}} = HostKeys.pin(host)
    end
  end

  describe "accept/3" do
    test "stores the new key only when the host presents the confirmed fingerprint" do
      host = host_fixture(%{key_fingerprint: @ecdsa_fp})
      MockClient.set_host_keys(host.id, [@ed])

      assert {:ok, accepted} = HostKeys.accept(host, @ed_fp, actor: "admin")
      assert accepted.key_fingerprint == @ed_fp
      assert accepted.host_key == @ed
      assert [{_, opts}] = MockClient.calls().probe
      assert opts[:expect] == @ed_fp

      assert [entry] = Activity.list(activity_type: "host")
      assert entry.action == "accept_host_key"
      assert entry.meta =~ @ecdsa_fp
      assert entry.meta =~ @ed_fp
    end

    test "refuses when the host presents yet another key" do
      host = host_fixture(%{key_fingerprint: @ecdsa_fp})
      MockClient.set_host_keys(host.id, [@ed])

      assert {:error, {:host_key_changed, %{offered: %{fingerprint: @ed_fp}}}} =
               HostKeys.accept(host, "ssh-rsa " <> @rsa_hash)

      assert Hosts.get_host(host.id).key_fingerprint == @ecdsa_fp
    end

    test "refuses an invalid fingerprint without SSH" do
      host = host_fixture()
      assert {:error, :invalid_fingerprint} = HostKeys.accept(host, "nope")
      assert MockClient.calls().probe == []
    end

    test "disabled host is refused" do
      host = host_fixture(%{disabled: true})
      assert {:error, {:host_disabled, _}} = HostKeys.accept(host, @ed_fp)
    end
  end

  describe "pin_all/1" do
    test "pins enabled hosts, jump hosts first, and lists failures" do
      bastion = host_fixture(%{name: "bastion"})
      leaf = host_fixture(%{name: "leaf", jump_via: bastion.id})
      broken = host_fixture(%{name: "broken"})
      _off = host_fixture(%{name: "off", disabled: true})

      MockClient.set_host_keys(bastion.id, [@ed])
      MockClient.set_host_keys(leaf.id, [@ecdsa])
      MockClient.fail_connect(broken.id)

      report = HostKeys.pin_all(actor: "admin")

      assert Enum.sort(report.pinned) == ["bastion", "leaf"]
      assert report.already == []
      assert [{"broken", {:ssh_connect_failed, _}}] = report.failed

      probed = Enum.map(MockClient.calls().probe, &elem(&1, 0))

      assert Enum.find_index(probed, &(&1 == bastion.id)) <
               Enum.find_index(probed, &(&1 == leaf.id))

      assert Hosts.get_host(leaf.id).key_fingerprint == @ecdsa_fp
    end
  end

  describe "Host changeset (pre-seeding)" do
    test "normalises ssh-keygen -l output" do
      host =
        host_fixture(%{
          key_fingerprint:
            "256 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q root@x (ED25519)"
        })

      assert host.key_fingerprint == @ed_fp
    end

    test "rejects a non-fingerprint" do
      assert {:error, changeset} =
               Hosts.create_host(%{
                 name: "x",
                 username: "root",
                 address: "1.1.1.1",
                 port: 22,
                 key_fingerprint: "MD5:aa:bb"
               })

      assert %{key_fingerprint: [_]} = errors_on(changeset)
    end

    test "blank clears the pin" do
      host = host_fixture(%{key_fingerprint: @ed_fp})
      {:ok, host} = Hosts.update_host(host, %{key_fingerprint: ""})
      assert host.key_fingerprint == nil
    end

    test "changing the fingerprint drops a stored public key that no longer matches" do
      host = host_fixture(%{key_fingerprint: @ed_fp})
      {:ok, host} = HostKeys.store_key(host, %{public_key: @ed, fingerprint: @ed_fp})

      {:ok, host} = Hosts.update_host(host, %{key_fingerprint: @ecdsa_fp})
      assert host.host_key == nil
    end
  end
end
