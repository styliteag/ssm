defmodule Ssm.Ssh.ErlangClientAddressTest do
  @moduledoc """
  How the production client hands an address to `:ssh.connect`: IPv4 and
  IPv6 literals as parsed tuples (IPv6 with `inet: :inet6`), a DNS name as
  a name, tried over IPv4 first and over IPv6 when IPv4 has no record.
  No network: only the connect arguments are checked.
  """

  use ExUnit.Case, async: true

  alias Ssm.Ssh.ErlangClient

  describe "connect_attempts/1" do
    test "an IPv6 literal connects to the parsed address over IPv6" do
      assert ErlangClient.connect_attempts("fdfd:4444:5::6:1") ==
               [{{0xFDFD, 0x4444, 5, 0, 0, 0, 6, 1}, [inet: :inet6]}]

      assert [{{0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}, [inet: :inet6]}] =
               ErlangClient.connect_attempts("2001:db8::5")
    end

    test "an IPv4 literal connects to the parsed address over IPv4" do
      assert ErlangClient.connect_attempts("10.40.6.1") == [{{10, 40, 6, 1}, [inet: :inet]}]
    end

    test "a DNS name is tried over IPv4 first, then over IPv6" do
      assert ErlangClient.connect_attempts("dev.example") == [
               {~c"dev.example", [inet: :inet]},
               {~c"dev.example", [inet: :inet6]}
             ]
    end
  end

  describe "retry_over_ipv6?/1" do
    test "only a missing IPv4 record moves on to the IPv6 attempt" do
      assert ErlangClient.retry_over_ipv6?({:error, :nxdomain})
      assert ErlangClient.retry_over_ipv6?({:error, {:nxdomain, :inet}})
      refute ErlangClient.retry_over_ipv6?({:error, :econnrefused})
      refute ErlangClient.retry_over_ipv6?({:error, :timeout})
      refute ErlangClient.retry_over_ipv6?({:ok, self()})
    end
  end
end
