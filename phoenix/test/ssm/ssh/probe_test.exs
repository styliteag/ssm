defmodule Ssm.Ssh.ProbeTest do
  # changes the global :probe_allow_loopback setting in one test
  use ExUnit.Case, async: false

  alias Ssm.MctlFixtures
  alias Ssm.Ssh.{ErlangClient, Probe, Target}

  describe "direct probe" do
    test "an SSH server answers: open with its banner" do
      port = MctlFixtures.ssh_banner_server("SSH-2.0-OpenSSH_10.2\r\n")

      assert {:ok, [%{port: ^port, open: true, banner: "SSH-2.0-OpenSSH_10.2", error: nil}]} =
               Probe.run("127.0.0.1", [port])
    end

    test "something else answers: open, no banner" do
      port = MctlFixtures.ssh_banner_server("HTTP/1.1 400 Bad Request\r\n")

      assert {:ok, [%{open: true, banner: nil, error: "no SSH banner"}]} =
               Probe.run("127.0.0.1", [port])
    end

    test "a closed port: not open, one result per port in order" do
      {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, closed} = :inet.port(l)
      :gen_tcp.close(l)
      ssh = MctlFixtures.ssh_banner_server()

      assert {:ok,
              [
                %{port: ^closed, open: false, error: "connection refused"},
                %{port: ^ssh, open: true}
              ]} =
               Probe.run("127.0.0.1", [closed, ssh])
    end

    test "loopback is refused outside tests" do
      Application.put_env(:ssm, :probe_allow_loopback, false)
      on_exit(fn -> Application.put_env(:ssm, :probe_allow_loopback, true) end)

      assert {:error, {:validation, %{"address" => [reason]}}} = Probe.run("127.0.0.1", [22])
      assert reason =~ "loopback"
      assert {:error, {:validation, _}} = Probe.run("::1", [22])
    end

    test "link-local, unspecified and multicast targets are refused" do
      for address <- ~w(169.254.1.1 fe80::1 0.0.0.0 :: 224.0.0.1 ff02::1) do
        assert {:error, {:validation, %{"address" => [_]}}} = Probe.run(address, [22]), address
      end
    end

    test "a name that does not resolve is refused" do
      assert {:error, {:validation, %{"address" => ["does not resolve"]}}} =
               Probe.run("no-such-host.invalid", [22])
    end
  end

  describe "through a jump host" do
    defmodule JumpStub do
      def banner_via(jump, address, port, _timeout) do
        send(self(), {:banner_via, jump.name, address, port})

        if port == 22,
          do: {:ok, "SSH-2.0-behind\r\n"},
          else: {:error, "connect failed: Connection refused"}
      end
    end

    setup do
      Application.put_env(:ssm, :probe_jump_client, JumpStub)
      on_exit(fn -> Application.delete_env(:ssm, :probe_jump_client) end)
    end

    test "the jump host connects; a DNS name is left to it" do
      jump = %Target{host_id: 1, name: "gw", address: "203.0.113.5", port: 9922, username: "root"}

      assert {:ok,
              [%{port: 22, open: true, banner: "SSH-2.0-behind"}, %{port: 2222, open: false}]} =
               Probe.run("db.internal", [22, 2222], jump)

      assert_received {:banner_via, "gw", "db.internal", 22}
    end

    test "an address literal is still checked" do
      jump = %Target{host_id: 1, name: "gw", address: "203.0.113.5", port: 22, username: "root"}
      assert {:error, {:validation, _}} = Probe.run("169.254.0.9", [22], jump)
    end

    test "loopback names are refused like loopback literals" do
      Application.put_env(:ssm, :probe_allow_loopback, false)
      on_exit(fn -> Application.put_env(:ssm, :probe_allow_loopback, true) end)
      jump = %Target{host_id: 1, name: "gw", address: "203.0.113.5", port: 22, username: "root"}

      for name <- ~w(localhost LOCALHOST. db.localhost localhost.localdomain ip6-localhost) do
        assert {:error, {:validation, %{"address" => [reason]}}} = Probe.run(name, [22], jump),
               name

        assert reason =~ "loopback"
      end

      refute_received {:banner_via, _, _, _}
    end
  end

  test "ssh -W argv: target as -W spec, jump host as destination, outer hops as -J" do
    outer = %Target{host_id: 2, name: "edge", address: "198.51.100.1", port: 22, username: "ops"}

    jump = %Target{
      host_id: 1,
      name: "gw",
      address: "fdfd:4444:5::1",
      port: 9922,
      username: "root",
      jump_target: outer
    }

    assert ErlangClient.probe_args(jump, "fdfd:4444:5::6:1", 22, "/k/cfg", "/k/id") == [
             "-F",
             "/k/cfg",
             "-W",
             "[fdfd:4444:5::6:1]:22",
             "-i",
             "/k/id",
             "-l",
             "root",
             "-p",
             "9922",
             "-J",
             "ops@198.51.100.1:22",
             "--",
             "fdfd:4444:5::1"
           ]
  end
end
