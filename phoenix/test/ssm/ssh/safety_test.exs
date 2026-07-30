defmodule Ssm.Ssh.SafetyTest do
  use ExUnit.Case, async: false

  alias Ssm.Ssh.{MockClient, Result, Safety, Target}

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp target(host_id \\ 1) do
    %Target{host_id: host_id, name: "web1", address: "10.0.0.1", port: 22, username: "root"}
  end

  describe "ensure_host_not_disabled/1" do
    test "passes enabled hosts" do
      assert Safety.ensure_host_not_disabled(%{disabled: false, name: "web1"}) == :ok
    end

    test "blocks disabled hosts before any connection is made" do
      assert {:error, {:host_disabled, message}} =
               Safety.ensure_host_not_disabled(%{disabled: true, name: "web1"})

      assert message =~ "web1"
      assert MockClient.calls().connect == []
    end
  end

  describe "check_readonly / ensure_writable" do
    test "no sentinel output means writable" do
      MockClient.set_default_exec(%Result{stdout: "", exit_code: 0})

      assert Safety.check_readonly(MockClient, target(), "deploy") == {:ok, nil}
      assert Safety.ensure_writable(MockClient, target(), "deploy") == :ok
    end

    test "system_readonly output blocks writes with the reason" do
      MockClient.set_default_exec(%Result{stdout: "system_readonly: frozen by ops\n"})

      assert {:ok, "system_readonly: frozen by ops"} =
               Safety.check_readonly(MockClient, target(), "deploy")

      assert {:error, {:ssh_readonly, message}} =
               Safety.ensure_writable(MockClient, target(), "deploy")

      assert message =~ "frozen by ops"
      assert message =~ "deploy"
    end

    test "the probe command passes the login through quoted" do
      MockClient.set_default_exec(%Result{stdout: ""})
      {:ok, nil} = Safety.check_readonly(MockClient, target(), "we ird$login")

      [{1, command}] = MockClient.calls().exec
      assert command =~ "'we ird$login'"
    end

    test "connect failures propagate" do
      MockClient.fail_connect(1)

      assert {:error, {:ssh_connect_failed, _}} =
               Safety.ensure_writable(MockClient, target(), "deploy")
    end
  end
end
