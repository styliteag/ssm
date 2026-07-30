defmodule Ssm.DiffsTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs
  alias Ssm.Diffs.{HostDiff, KeyDiff, LoginDiff}
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  # get_ssh_keyfiles/set_authorized_keyfile call ensure_uploaded first, which
  # runs the version probe; make the remote script look current for that host.
  defp stub_version(host_id) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})
  end

  defp keyfiles_json(entries), do: Jason.encode!(entries)

  describe "host_diff/2" do
    test "classifies present / missing_on_host / extra_on_host" do
      user = user_fixture()
      host = host_fixture()
      key = key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "EXPECTED1", name: "laptop"})
      authorization_fixture(user, host, %{login: "deploy"})

      expected_line = "ssh-ed25519 EXPECTED1 laptop"
      extra_line = "ssh-rsa UNMANAGED root@old"

      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
        stdout:
          keyfiles_json([
            %{
              login: "deploy",
              has_pragma: true,
              readonly_condition: nil,
              keyfile: "#{extra_line}"
            }
          ])
      })

      assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert %LoginDiff{login: "deploy", has_pragma: true} = login

      statuses = Map.new(login.items, &{&1.line, &1.status})
      assert statuses[expected_line] == :missing_on_host
      assert statuses[extra_line] == :extra_on_host
      _ = key
    end

    test "a key present on both sides is :present" do
      user = user_fixture()
      host = host_fixture()
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "BOTH", name: nil})
      authorization_fixture(user, host, %{login: "deploy"})

      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
        stdout:
          keyfiles_json([
            %{
              login: "deploy",
              has_pragma: false,
              readonly_condition: nil,
              keyfile: "ssh-ed25519 BOTH"
            }
          ])
      })

      {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert [%KeyDiff{status: :present, line: "ssh-ed25519 BOTH"}] = login.items
    end

    test "a disabled host short-circuits before any SSH" do
      host = host_fixture(%{disabled: true})

      assert {:error, {:host_disabled, message}} = Diffs.host_diff(MockClient, host.id)
      assert message =~ host.name
      assert MockClient.calls().exec == []
    end

    test "unknown host is :not_found" do
      assert Diffs.host_diff(MockClient, 999_999) == {:error, :not_found}
    end

    test "a read error is surfaced per login without crashing" do
      user = user_fixture()
      host = host_fixture()
      key_fixture(user, %{key_base64: "K1", name: nil, key_type: "ssh-ed25519"})
      authorization_fixture(user, host, %{login: "deploy"})

      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
        stderr: "connection refused",
        exit_code: 255
      })

      {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert login.read_error =~ "connection refused"
      # Expected keys still show as missing_on_host.
      assert Enum.all?(login.items, &(&1.status == :missing_on_host))
    end
  end

  describe "sync_host/2" do
    test "writes expected keys for each login and reports counts" do
      user = user_fixture()
      host = host_fixture()
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "SYNCME", name: "laptop"})
      authorization_fixture(user, host, %{login: "deploy"})

      stub_version(host.id)
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert {:ok, [synced]} = Diffs.sync_host(MockClient, host.id)
      assert synced.login == "deploy"
      assert synced.written_keys == 1

      write =
        Enum.find(MockClient.calls().exec_inputs, fn {_id, cmd, _} ->
          String.contains?(cmd, "set_authorized_keyfile deploy")
        end)

      assert {_, _, "ssh-ed25519 SYNCME laptop\n"} = write
    end

    test "bails atomically on a readonly login" do
      user = user_fixture()
      host = host_fixture()
      key_fixture(user, %{key_base64: "RO", name: nil, key_type: "ssh-ed25519"})
      authorization_fixture(user, host, %{login: "deploy"})

      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh set_authorized_keyfile deploy", %Result{
        stderr: "readonly: system_readonly set",
        exit_code: 1
      })

      assert {:error, {:ssh_readonly, message}} = Diffs.sync_host(MockClient, host.id)
      assert message =~ "readonly"
    end

    test "disabled host is refused" do
      host = host_fixture(%{disabled: true})
      assert {:error, {:host_disabled, _}} = Diffs.sync_host(MockClient, host.id)
    end
  end

  describe "compute_diff/2 (pure)" do
    test "sorts within each status group" do
      result = Diffs.compute_diff(["b", "a"], ["a", "z"])

      assert result == [
               %KeyDiff{status: :present, line: "a"},
               %KeyDiff{status: :missing_on_host, line: "b"},
               %KeyDiff{status: :extra_on_host, line: "z"}
             ]
    end
  end
end
