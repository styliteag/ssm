defmodule Ssm.Ssh.ErlangClientArgsTest do
  @moduledoc """
  Host username/address reach the argv of the local OpenSSH forwarder (jump
  chains). Regression tests for argument injection: values that could be
  parsed as ssh options are refused before any connection or process, and
  the argv never puts a host field where an option could be.
  """

  use ExUnit.Case, async: false

  alias Ssm.Ssh.{ErlangClient, Target}

  @moduletag :tmp_dir
  @proxy_command "-oProxyCommand=touch /tmp/ssm-pwned;#"

  setup %{tmp_dir: dir} do
    start_supervised!({ErlangClient, key_dir: dir})
    :ok
  end

  defp target(id, attrs) do
    struct!(
      %Target{host_id: id, name: "h#{id}", address: "10.0.0.#{id}", port: 22, username: "root"},
      attrs
    )
  end

  test "a ProxyCommand username on a jump hop is refused before any ssh process" do
    leaf = target(3, jump_target: target(2, username: @proxy_command))

    assert {:error, {:ssh_connect_failed, message}} = ErlangClient.connect(leaf)
    assert message =~ "h2"
    assert message =~ "username"
    refute message =~ "ProxyCommand"
  end

  test "a dash-leading address is refused, direct or as a hop" do
    assert {:error, {:ssh_connect_failed, message}} =
             ErlangClient.connect(target(4, address: "-oProxyCommand=x"))

    assert message =~ "address"

    assert {:error, {:ssh_connect_failed, _}} =
             ErlangClient.connect(target(5, jump_target: target(6, address: "-x")))
  end

  test "forwarder argv: -l/-p options and `--` before the destination" do
    outer = target(4, address: "2001:db8::4", port: 2200, username: "jo")
    inner = target(3, address: "10.0.0.3", username: "ji", jump_target: outer)
    leaf = target(5, address: "2001:db8::5", username: "lu", jump_target: inner)

    args = ErlangClient.forwarder_args(leaf, "/k/id", 40_000)

    assert Enum.take(args, -2) == ["--", "10.0.0.3"]
    assert ["-l", "ji"] == args |> Enum.drop_while(&(&1 != "-l")) |> Enum.take(2)
    assert ["-p", "22"] == args |> Enum.drop_while(&(&1 != "-p")) |> Enum.take(2)

    assert ["-J", "jo@[2001:db8::4]:2200"] ==
             args |> Enum.drop_while(&(&1 != "-J")) |> Enum.take(2)

    assert "127.0.0.1:40000:[2001:db8::5]:22" in args
    refute Enum.any?(args, &String.contains?(&1, "ji@"))
  end
end
