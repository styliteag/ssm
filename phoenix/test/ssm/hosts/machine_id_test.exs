defmodule Ssm.Hosts.MachineIdTest do
  use Ssm.DataCase, async: false

  import ExUnit.CaptureLog
  import Ssm.Fixtures

  alias Ssm.Hosts
  alias Ssm.Hosts.MachineId
  alias Ssm.Ssh.{MockClient, Result}

  # identity-claims-v1 reference vector (dashboard agent 60-identity.py).
  @raw "0123456789abcdef0123456789abcdef"
  @hmac "7f6b554ff5b43db2137ea2a70f5f40b584d6f4384399cdaaace85722c78c705f"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp script(host, stdout, exit_code \\ 0) do
    MockClient.set_exec(host.id, MachineId.command(), %Result{
      stdout: stdout,
      exit_code: exit_code
    })
  end

  test "derive/1 matches the reference vector and trims" do
    assert MachineId.derive(@raw) == @hmac
    assert MachineId.derive(@raw <> "\n") == @hmac
  end

  test "command is fixed and covers Linux and FreeBSD" do
    assert MachineId.command() =~ "cat /etc/machine-id"
    assert MachineId.command() =~ "sysctl -n kern.hostuuid"
  end

  test "stores only the HMAC" do
    host = host_fixture()
    script(host, @raw <> "\n")

    assert %{machine_id: @hmac} = MachineId.refresh(host, [])
    assert Hosts.get_host(host.id).machine_id == @hmac
    refute inspect(Hosts.get_host(host.id)) =~ @raw
  end

  test "failure keeps the old value and never logs the raw id" do
    host = host_fixture()
    script(host, @raw)
    host = MachineId.refresh(host, [])

    for {stdout, code} <- [{@raw, 1}, {"", 0}, {"  \n", 0}] do
      script(host, stdout, code)
      log = capture_log(fn -> assert %{machine_id: @hmac} = MachineId.refresh(host, []) end)
      refute log =~ @raw
    end

    MockClient.fail_connect(host.id)
    assert %{machine_id: @hmac} = MachineId.refresh(host, [])
    assert Hosts.get_host(host.id).machine_id == @hmac
  end

  test "a changed id replaces the old HMAC" do
    host = host_fixture()
    script(host, @raw)
    host = MachineId.refresh(host, [])
    script(host, "fedcba9876543210")

    assert %{machine_id: new} = MachineId.refresh(host, [])
    assert new == MachineId.derive("fedcba9876543210")
    assert new != @hmac
  end

  test "disabled host: no SSH at all" do
    host = host_fixture(%{disabled: true})

    assert %{machine_id: nil} = MachineId.refresh(host, [])
    assert MockClient.calls().exec == []
    assert MockClient.calls().connect == []
  end
end
