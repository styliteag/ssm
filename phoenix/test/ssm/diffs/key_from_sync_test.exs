defmodule Ssm.Diffs.KeyFromSyncTest do
  @moduledoc """
  `SSM_KEY_FROM`: a sync writes ssm's own key with `from="<list>"` when the
  host sees ssm at an address in the list, without it otherwise (no
  lockout), and as before when the list is empty.
  """
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"
  @client_cmd ~s(printf '%s' "${SSH_CONNECTION%% *}")
  @own Ssm.Test.OwnKeyStub.default()

  setup do
    start_supervised!(MockClient)
    on_exit(fn -> Application.delete_env(:ssm, :key_from) end)
    :ok
  end

  defp stub_host(host, client_address) do
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "GRANTED", name: "k"})
    authorization_fixture(user, host, %{login: "root"})
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    MockClient.set_exec(host.id, @get_keyfiles, %Result{
      stdout: Jason.encode!([%{login: "root", has_pragma: true, keyfile: "#{@own} ssm"}])
    })

    MockClient.set_exec(host.id, @client_cmd, %Result{stdout: client_address})
    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp root_write(host) do
    Enum.find_value(MockClient.calls().exec_inputs, fn
      {id, "sh .ssm/script.sh set_authorized_keyfile root " <> _, input} when id == host.id ->
        input

      _ ->
        nil
    end)
  end

  test "own key gets from= when the host sees ssm inside the list" do
    Application.put_env(:ssm, :key_from, ["10.40.0.0/16", "192.0.2.7"])
    host = host_fixture(%{username: "root"})
    stub_host(host, "10.40.6.1")

    assert {:ok, _} = Diffs.sync_host(host.id)
    assert root_write(host) =~ ~s(from="10.40.0.0/16,192.0.2.7" #{@own} ssm)
  end

  test "outside the list: no from=, never a lockout" do
    Application.put_env(:ssm, :key_from, ["10.40.0.0/16"])
    host = host_fixture(%{username: "root"})
    stub_host(host, "203.0.113.9")

    assert {:ok, _} = Diffs.sync_host(host.id)
    refute root_write(host) =~ "from="
    assert root_write(host) =~ "#{@own} ssm"
  end

  test "empty list: unchanged, the client address is not even asked" do
    host = host_fixture(%{username: "root"})
    stub_host(host, "10.40.6.1")

    assert {:ok, _} = Diffs.sync_host(host.id)
    refute root_write(host) =~ "from="
    refute Enum.any?(MockClient.calls().exec, &(inspect(&1) =~ "SSH_CONNECTION"))
  end
end
