defmodule Ssm.Ssh.ScriptRunnerTest do
  use ExUnit.Case, async: false

  alias Ssm.Ssh.{MockClient, Result, ScriptRunner, Target}
  alias Ssm.Ssh.ScriptRunner.LoginKeyfile

  @remote "sh .ssm/script.sh"

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp target,
    do: %Target{host_id: 7, name: "web1", address: "10.0.0.1", port: 22, username: "root"}

  defp stub_version_current do
    payload = Jason.encode!(%{version: "x", sha256: ScriptRunner.script_sha256()})

    MockClient.set_exec(7, "#{@remote} version 2>/dev/null || true", %Result{stdout: payload})
  end

  defp stub_version_stale do
    MockClient.set_exec(7, "#{@remote} version 2>/dev/null || true", %Result{stdout: ""})
  end

  describe "ensure_uploaded/2" do
    test "no-op when the remote sha matches" do
      stub_version_current()

      assert ScriptRunner.ensure_uploaded(MockClient, target()) == :ok
      assert length(MockClient.calls().exec) == 1
    end

    test "uploads via exec+stdin when missing or stale" do
      stub_version_stale()
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert ScriptRunner.ensure_uploaded(MockClient, target()) == :ok

      upload =
        Enum.find(MockClient.calls().exec_inputs, fn {_id, cmd, _input} ->
          String.contains?(cmd, "cat > .ssm/script.sh")
        end)

      assert {7, command, input} = upload
      assert command =~ "mkdir -p .ssm"
      assert command =~ "chmod 0700 .ssm/script.sh"
      assert input == ScriptRunner.script_source()
      assert input =~ "get_ssh_keyfiles"
    end
  end

  describe "get_ssh_keyfiles/2" do
    test "parses the JSON list and unescapes newlines" do
      stub_version_current()

      json =
        Jason.encode!([
          %{
            login: "deploy",
            has_pragma: true,
            readonly_condition: "",
            keyfile: "ssh-ed25519 AAAA one\\nssh-rsa BBBB two"
          },
          %{
            login: "root",
            has_pragma: false,
            readonly_condition: "user_readonly: no",
            keyfile: ""
          }
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})

      assert {:ok, [deploy, root]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())

      assert %LoginKeyfile{login: "deploy", has_pragma: true, readonly_condition: nil} = deploy
      assert deploy.keyfile == "ssh-ed25519 AAAA one\nssh-rsa BBBB two"
      assert %LoginKeyfile{login: "root", readonly_condition: "user_readonly: no"} = root
    end

    test "empty stdout is an empty list" do
      stub_version_current()
      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: "  \n"})

      assert ScriptRunner.get_ssh_keyfiles(MockClient, target()) == {:ok, []}
    end

    test "non-JSON output is an ssh_connect_failed error" do
      stub_version_current()
      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: "garbage"})

      assert {:error, {:ssh_connect_failed, message}} =
               ScriptRunner.get_ssh_keyfiles(MockClient, target())

      assert message =~ "non-JSON"
    end

    test "non-zero exit is an ssh_connect_failed error with stderr" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{
        stderr: "boom",
        exit_code: 3
      })

      assert {:error, {:ssh_connect_failed, message}} =
               ScriptRunner.get_ssh_keyfiles(MockClient, target())

      assert message =~ "boom"
    end
  end

  describe "set_authorized_keyfile/4" do
    test "pipes the content to the script with the login quoted" do
      stub_version_current()
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "key material\n") ==
               :ok

      assert {7, command, "key material\n"} =
               Enum.find(MockClient.calls().exec_inputs, fn {_, cmd, _} ->
                 String.contains?(cmd, "set_authorized_keyfile")
               end)

      assert command == "#{@remote} set_authorized_keyfile deploy"
    end

    test "a readonly refusal surfaces as ssh_readonly" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy", %Result{
        stderr: "refusing write: readonly (system_readonly set)",
        exit_code: 1
      })

      assert {:error, {:ssh_readonly, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "keys")

      assert message =~ "system_readonly"
    end

    test "other failures surface as ssh_connect_failed" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy", %Result{
        stderr: "disk full",
        exit_code: 1
      })

      assert {:error, {:ssh_connect_failed, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "keys")

      assert message =~ "disk full"
    end
  end

  test "version/2 returns the parsed self-report" do
    MockClient.set_exec(7, "#{@remote} version", %Result{
      stdout: ~s({"version":"v0.3-alpha","sha256":"abc"})
    })

    assert ScriptRunner.version(MockClient, target()) ==
             {:ok, %{"version" => "v0.3-alpha", "sha256" => "abc"}}
  end

  test "the bundled script exposes the command dispatch the runner drives" do
    # Byte-identity with backend/src/ssm/ssh/script.sh is verified host-side
    # (the container only mounts phoenix/); here we assert the contract the
    # runner depends on is present in the bundled copy.
    source = ScriptRunner.script_source()

    for command <- ~w(set_authorized_keyfile get_ssh_keyfiles version) do
      assert source =~ command, "script.sh is missing the #{command} subcommand"
    end

    assert source =~ "system_readonly"
    assert source =~ "has_pragma"
  end
end
