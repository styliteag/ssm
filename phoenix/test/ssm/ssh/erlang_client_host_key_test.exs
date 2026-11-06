defmodule Ssm.Ssh.ErlangClientHostKeyTest do
  @moduledoc """
  ADR-0008 host-key pinning in the production client, exercised against an
  in-process Erlang `:ssh.daemon` bound to 127.0.0.1 on an ephemeral port —
  a fake SSH server owned by the test, never a real host.
  """

  use ExUnit.Case, async: false

  alias Ssm.Ssh.{ErlangClient, HostKey, Target}

  @moduletag :tmp_dir

  defmodule FakeServerKeyCb do
    @moduledoc false
    @behaviour :ssh_server_key_api

    @impl true
    def host_key(_algorithm, opts), do: {:ok, Keyword.fetch!(opts[:key_cb_private], :host_key)}

    @impl true
    def is_auth_key(_public_key, _user, _opts), do: true
  end

  setup %{tmp_dir: tmp_dir} do
    :ok = ensure_ssh()
    key_dir = Path.join(tmp_dir, "keys")
    File.mkdir_p!(key_dir)
    File.chmod!(key_dir, 0o700)

    # Client key: RSA PEM, which :ssh_file reads natively as id_rsa.
    client_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, client_key)])
    File.write!(Path.join(key_dir, "id_rsa"), pem)
    File.chmod!(Path.join(key_dir, "id_rsa"), 0o600)

    host_key = :public_key.generate_key({:namedCurve, :ed25519})
    {:ok, daemon} = start_daemon(tmp_dir, host_key)
    {:ok, info} = :ssh.daemon_info(daemon)
    on_exit(fn -> :ssh.stop_daemon(daemon) end)

    start_supervised!({ErlangClient, key_dir: key_dir})

    {:ok, offered} = host_key |> public_part() |> HostKey.from_erlang_key()

    {:ok, port: Keyword.fetch!(info, :port), offered: offered, key_dir: key_dir}
  end

  defp ensure_ssh do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, :ssh}} -> :ok
    end
  end

  defp start_daemon(tmp_dir, host_key) do
    :ssh.daemon({127, 0, 0, 1}, 0,
      system_dir: String.to_charlist(tmp_dir),
      key_cb: {FakeServerKeyCb, host_key: host_key},
      auth_methods: ~c"publickey"
    )
  end

  defp public_part({:ECPrivateKey, _, _priv, params, pub, _}), do: {{:ECPoint, pub}, params}

  defp target(port, fingerprint, id \\ 1) do
    %Target{
      host_id: id,
      name: "fake#{id}",
      address: "127.0.0.1",
      port: port,
      username: "root",
      host_key_fingerprint: fingerprint
    }
  end

  @other "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"

  test "connects when the pinned fingerprint matches", %{port: port, offered: offered} do
    assert :ok = ErlangClient.connect(target(port, offered.fingerprint))
    refute_received {:ssm_host_key, _, _}
  end

  test "a bare legacy SHA256 pin matches too", %{port: port, offered: offered} do
    [_type, hash] = String.split(offered.fingerprint, " ")
    assert :ok = ErlangClient.connect(target(port, hash))
  end

  test "refuses a changed host key with both fingerprints in the error",
       %{port: port, offered: offered} do
    assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(target(port, @other))
    assert message =~ "host key changed"
    assert message =~ @other
    assert message =~ offered.fingerprint
    refute_received {:ssm_host_key, _, _}
  end

  test "refuses an unpinned host without connecting", %{port: port} do
    assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(target(port, nil))
    assert message =~ "not pinned"
  end

  test "probe captures the key of an unpinned host (TOFU path) without caching a connection",
       %{port: port, offered: offered} do
    assert {:ok, ^offered} = ErlangClient.probe_host_key(target(port, nil), [])
    # Still unpinned for normal operations: the probe pins nothing by itself.
    assert {:error, {:ssh_connect_failed, _}} = ErlangClient.connect(target(port, nil))
  end

  test "probe with an expected fingerprint refuses another key before auth",
       %{port: port, offered: offered} do
    assert {:error, {:host_key_mismatch, ^offered}} =
             ErlangClient.probe_host_key(target(port, nil), expect: @other)

    assert {:ok, ^offered} =
             ErlangClient.probe_host_key(target(port, nil), expect: offered.fingerprint)
  end

  test "a jump hop without a full pinned public key is refused before spawning ssh",
       %{port: port, offered: offered} do
    jump = %{target(port, offered.fingerprint, 2) | host_key: nil}
    leaf = %{target(port, offered.fingerprint, 3) | jump_target: jump}

    assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(leaf)
    assert message =~ "jump host fake2"
    assert message =~ "public key"
  end

  test "a jump hop whose address could inject known_hosts entries is refused",
       %{port: port, offered: offered} do
    jump = %{
      target(port, offered.fingerprint, 2)
      | host_key: offered.public_key,
        address: "evil.example\n* ssh-ed25519 AAAA"
    }

    leaf = %{target(port, offered.fingerprint, 3) | jump_target: jump}
    assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(leaf)
    assert message =~ "host fake2 has an invalid address"
  end

  describe "argument injection (legacy rows that bypass validation)" do
    @proxy_command "-oProxyCommand=touch /tmp/ssm-pwned;#"

    test "a ProxyCommand username on a jump hop is refused before any ssh process",
         %{port: port, offered: offered} do
      jump = %{
        target(port, offered.fingerprint, 2)
        | host_key: offered.public_key,
          username: @proxy_command
      }

      leaf = %{target(port, offered.fingerprint, 3) | jump_target: jump}
      assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(leaf)
      assert message =~ "fake2"
      assert {:error, {:ssh_connect_failed, _}} = ErlangClient.probe_host_key(leaf, [])
    end

    test "a dash-leading address is refused for direct targets too", %{port: port} do
      bad = %{target(port, "ssh-ed25519 SHA256:x") | address: "-oProxyCommand=x"}
      assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(bad)
      assert message =~ "address"
      assert {:error, {:ssh_connect_failed, _}} = ErlangClient.probe_host_key(bad, [])
    end

    test "forwarder argv: -l/-p options and `--` before the destination" do
      outer = %Target{host_id: 4, name: "o", address: "2001:db8::4", port: 2200, username: "jo"}

      inner = %Target{
        host_id: 3,
        name: "i",
        address: "10.0.0.3",
        port: 22,
        username: "ji",
        jump_target: outer
      }

      leaf = %Target{
        host_id: 5,
        name: "l",
        address: "2001:db8::5",
        port: 22,
        username: "lu",
        jump_target: inner
      }

      args = ErlangClient.forwarder_args(leaf, "/k/cfg", "/k/id", 40_000)

      assert Enum.take(args, -2) == ["--", "10.0.0.3"]
      assert ["-l", "ji"] == args |> Enum.drop_while(&(&1 != "-l")) |> Enum.take(2)
      assert ["-p", "22"] == args |> Enum.drop_while(&(&1 != "-p")) |> Enum.take(2)

      assert ["-J", "jo@[2001:db8::4]:2200"] ==
               args |> Enum.drop_while(&(&1 != "-J")) |> Enum.take(2)

      assert "127.0.0.1:40000:[2001:db8::5]:22" in args
      refute Enum.any?(args, &String.contains?(&1, "ji@"))
    end
  end

  describe "OpenSSH forwarder files" do
    test "known_hosts lists every hop with its pinned key", %{offered: offered} do
      inner = %Target{
        host_id: 2,
        name: "inner",
        address: "10.0.0.2",
        port: 2222,
        username: "u",
        host_key: offered.public_key
      }

      outer = %Target{
        host_id: 3,
        name: "outer",
        address: "bastion.example",
        port: 22,
        username: "u",
        host_key: offered.public_key
      }

      chain = %{inner | jump_target: outer}

      assert ErlangClient.known_hosts_content(chain) ==
               "[10.0.0.2]:2222 #{offered.public_key}\n" <>
                 "bastion.example #{offered.public_key}\n"
    end

    test "ssh config enforces strict checking against the generated file only" do
      config = ErlangClient.forwarder_config("/k/id_ed25519", "/k/known_hosts-7")

      assert config =~ "StrictHostKeyChecking yes"
      assert config =~ ~s(UserKnownHostsFile "/k/known_hosts-7")
      assert config =~ "GlobalKnownHostsFile /dev/null"
      assert config =~ ~s(IdentityFile "/k/id_ed25519")
      assert config =~ "BatchMode yes"
      refute config =~ "StrictHostKeyChecking no"
      refute config =~ "UserKnownHostsFile /dev/null"
    end
  end
end
