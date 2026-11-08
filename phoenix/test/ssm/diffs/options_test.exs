defmodule Ssm.Diffs.OptionsTest do
  @moduledoc """
  `authorization.options` are deployed: rendered in front of the key, and
  when set they win over the options of the host's line. Empty DB options
  keep the host's line (hand-typed options survive).
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs
  alias Ssm.Diffs.HostDiff
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp host_with_file(login, text) do
    host = host_fixture(%{username: "ssm-admin"})
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    entries = [%{login: login, has_pragma: true, readonly_condition: nil, keyfile: text}]
    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
    MockClient.set_default_exec(%Result{exit_code: 0})
    host
  end

  defp grant(host, base64, options) do
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: base64, name: "laptop"})
    authorization_fixture(user, host, %{login: "deploy", options: options})
  end

  defp written(host) do
    {_, _, input} =
      Enum.find(MockClient.calls().exec_inputs, fn {id, cmd, _} ->
        id == host.id and String.contains?(cmd, "set_authorized_keyfile deploy")
      end)

    input
  end

  defp items_of(host) do
    {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
    Enum.map(login.items, &{&1.status, &1.line})
  end

  test "the options are rendered in front of the key" do
    host = host_with_file("deploy", "")
    grant(host, "OPTKEY1", ~s(no-pty,from="10.0.0.0/8"))

    assert {:ok, [_]} = Diffs.sync_host(MockClient, host.id)
    assert written(host) == ~s(no-pty,from="10.0.0.0/8" ssh-ed25519 OPTKEY1 laptop\n)
  end

  test "DB options replace the options of the host's line" do
    host = host_with_file("deploy", ~s(from="192.0.2.1" ssh-ed25519 OPTKEY2 old))
    grant(host, "OPTKEY2", "restrict")

    assert {:ok, [_]} = Diffs.sync_host(MockClient, host.id)
    assert written(host) == "restrict ssh-ed25519 OPTKEY2 laptop\n"
  end

  test "empty DB options keep the host's line" do
    line = ~s(from="192.0.2.1",no-pty ssh-ed25519 OPTKEY3 handmade)
    host = host_with_file("deploy", line)
    grant(host, "OPTKEY3", nil)

    assert {:ok, [_]} = Diffs.sync_host(MockClient, host.id)
    assert written(host) == line <> "\n"
    assert items_of(host) == [{:present, line}]
  end

  test "an options mismatch is drift" do
    host_line = ~s(from="192.0.2.1" ssh-ed25519 OPTKEY4 laptop)
    host = host_with_file("deploy", host_line)
    grant(host, "OPTKEY4", "no-pty")

    assert items_of(host) == [
             {:missing_on_host, "no-pty ssh-ed25519 OPTKEY4 laptop"},
             {:extra_on_host, host_line}
           ]
  end

  test "matching options are present, whatever the comment" do
    host_line = "no-pty ssh-ed25519 OPTKEY5 other-comment"
    host = host_with_file("deploy", host_line)
    grant(host, "OPTKEY5", "no-pty")

    assert items_of(host) == [{:present, host_line}]
  end
end
