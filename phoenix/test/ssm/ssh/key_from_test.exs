defmodule Ssm.Ssh.KeyFromTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.KeyFrom

  test "parse accepts IPs and CIDRs, IPv4 and IPv6" do
    assert {:ok, ["213.183.76.0/24", "10.40.0.0/16", "2001:db8::/32", "192.0.2.7"]} =
             KeyFrom.parse(" 213.183.76.0/24, 10.40.0.0/16 ,2001:db8::/32,192.0.2.7 ")

    assert {:ok, []} = KeyFrom.parse(nil)
    assert {:ok, []} = KeyFrom.parse("")
  end

  test "parse refuses anything sshd would not take or that could break the line" do
    for bad <- ["10.0.0.0/33", "999.1.1.1", "host.example", "10.0.0.0/8\"", "*", "10.0.0.0/x"] do
      assert {:error, _} = KeyFrom.parse(bad), bad
    end
  end

  test "allowed? matches the client address against the list" do
    list = ["213.183.76.0/24", "10.40.0.0/16", "2001:db8::/32", "192.0.2.7"]

    for ip <- ["213.183.76.3", "10.40.6.1", "2001:db8::1", "192.0.2.7"],
        do: assert(KeyFrom.allowed?(list, ip), ip)

    for ip <- ["213.183.77.1", "10.41.0.1", "2001:db9::1", "192.0.2.8", "", nil, "junk"],
        do: refute(KeyFrom.allowed?(list, ip), inspect(ip))
  end

  test "option renders the from= option" do
    assert KeyFrom.option(["10.40.0.0/16", "192.0.2.7"]) == ~s(from="10.40.0.0/16,192.0.2.7")
    assert KeyFrom.option([]) == nil
  end
end
