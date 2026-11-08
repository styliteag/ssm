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

  describe "ssm's own key (Ssm.Ssh.OwnKey) in the login user's authorized_keys" do
    # ssm logs in with it (onboarding v2 puts it into ~root/.ssh/authorized_keys):
    # never drift, never removed by a sync
    @own Ssm.Test.OwnKeyStub.default()

    defp keyfile(host, login, text) do
      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
        stdout:
          keyfiles_json([
            %{login: login, has_pragma: true, readonly_condition: nil, keyfile: text}
          ])
      })
    end

    test "on the host it is :present, whatever its comment or options" do
      host = host_fixture(%{username: "root"})

      for line <- [
            "#{@own} ssm@mission-control",
            "#{@own}",
            ~s(from="10.0.0.0/8",no-pty #{@own} ssm)
          ] do
        keyfile(host, "root", line)
        assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
        assert [%KeyDiff{status: :present, line: ^line}] = login.items
      end
    end

    test "missing on the host is no drift either" do
      user = user_fixture()
      host = host_fixture(%{username: "root"})
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "OPKEY", name: "op"})
      authorization_fixture(user, host, %{login: "root"})
      keyfile(host, "root", "ssh-ed25519 OPKEY op")

      assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert Enum.map(login.items, & &1.status) == [:present]
    end

    test "in another login's file it is an ordinary extra key" do
      host = host_fixture(%{username: "root"})
      keyfile(host, "deploy", "#{@own} ssm")
      assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert [%KeyDiff{status: :extra_on_host}] = login.items
    end

    test "a sync of the login user keeps it; other logins do not get it" do
      user = user_fixture()
      host = host_fixture(%{username: "root"})
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "OPKEY", name: "op"})
      authorization_fixture(user, host, %{login: "root"})
      authorization_fixture(user, host, %{login: "deploy"})
      stub_version(host.id)
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert {:ok, synced} = Diffs.sync_host(MockClient, host.id)
      assert Enum.map(synced, &{&1.login, &1.written_keys}) == [{"deploy", 1}, {"root", 2}]

      writes =
        for {_id, cmd, input} <- MockClient.calls().exec_inputs,
            [_, login] <- [Regex.run(~r/set_authorized_keyfile (\S+)/, cmd)],
            into: %{},
            do: {login, input}

      assert writes["root"] == "ssh-ed25519 OPKEY op\n#{@own} ssm\n"
      assert writes["deploy"] == "ssh-ed25519 OPKEY op\n"
    end

    test "an admin-assigned copy of the own key is written once" do
      user = user_fixture()
      host = host_fixture(%{username: "root"})
      [type, b64] = String.split(@own)
      key_fixture(user, %{key_type: type, key_base64: b64, name: "ssm"})
      authorization_fixture(user, host, %{login: "root"})
      stub_version(host.id)
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert {:ok, [%{login: "root", written_keys: 1}]} = Diffs.sync_host(MockClient, host.id)
    end

    test "without the own key (SSH_KEY unreadable) nothing changes" do
      Application.put_env(:ssm, :test_own_public_key, :unavailable)
      on_exit(fn -> Application.delete_env(:ssm, :test_own_public_key) end)
      host = host_fixture(%{username: "root"})
      keyfile(host, "root", "#{@own} ssm")
      assert {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      assert [%KeyDiff{status: :extra_on_host}] = login.items
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

    test "a successful sync refreshes the machine_id HMAC; a failed read keeps the sync result" do
      user = user_fixture()
      host = host_fixture()
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "SYNCME", name: "laptop"})
      authorization_fixture(user, host, %{login: "deploy"})
      stub_version(host.id)
      MockClient.set_default_exec(%Result{exit_code: 0})

      MockClient.set_exec(host.id, Ssm.Hosts.MachineId.command(), %Result{
        stdout: "0123456789abcdef0123456789abcdef\n"
      })

      assert {:ok, [_]} = Diffs.sync_host(MockClient, host.id)

      assert Ssm.Hosts.get_host(host.id).machine_id ==
               "7f6b554ff5b43db2137ea2a70f5f40b584d6f4384399cdaaace85722c78c705f"

      MockClient.set_exec(host.id, Ssm.Hosts.MachineId.command(), %Result{exit_code: 1})
      assert {:ok, [_]} = Diffs.sync_host(MockClient, host.id)
      assert Ssm.Hosts.get_host(host.id).machine_id =~ ~r/\A7f6b554f/
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

  describe "key identity: type + base64, whatever comment, options or whitespace" do
    # prod 2026-11-08 (host dev, login root): a granted RSA key whose host
    # comment differed from the DB name was listed twice, "missing on host"
    # and "not authorized" ("Allow" then said the grant already exists)
    defp host_with_file(login, text) do
      host = host_fixture()
      stub_version(host.id)

      MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
        stdout:
          keyfiles_json([
            %{login: login, has_pragma: true, readonly_condition: nil, keyfile: text}
          ])
      })

      host
    end

    defp grant(host, login, attrs) do
      user = user_fixture()
      key_fixture(user, Map.merge(%{key_type: "ssh-rsa"}, attrs))
      authorization_fixture(user, host, %{login: login})
      user
    end

    defp items_of(host) do
      {:ok, %HostDiff{logins: [login]}} = Diffs.host_diff(MockClient, host.id)
      Enum.map(login.items, &{&1.status, &1.line})
    end

    test "a granted key with another comment on the host is :present once" do
      host = host_with_file("root", "ssh-rsa BLOB1 wb@laptop")
      grant(host, "root", %{key_base64: "BLOB1", name: "Wim Bonis RSA"})
      assert items_of(host) == [{:present, "ssh-rsa BLOB1 wb@laptop"}]
    end

    test "an options prefix on the host line does not hide the key" do
      line = ~s(from="10.0.0.0/8",no-pty ssh-rsa BLOB2 laptop)
      host = host_with_file("root", line)
      grant(host, "root", %{key_base64: "BLOB2", name: "laptop"})
      assert items_of(host) == [{:present, line}]
    end

    test "CRLF and trailing whitespace on the host are ignored" do
      host = host_with_file("root", "ssh-rsa BLOB3 laptop  \r\nssh-rsa EXTRA9 x\r\n")
      grant(host, "root", %{key_base64: "BLOB3", name: "laptop"})

      assert items_of(host) == [
               {:present, "ssh-rsa BLOB3 laptop"},
               {:extra_on_host, "ssh-rsa EXTRA9 x"}
             ]
    end

    test "a DB key without a name matches a host line with a comment, and the reverse" do
      host = host_with_file("root", "ssh-rsa BLOB4 laptop\nssh-rsa BLOB5")
      grant(host, "root", %{key_base64: "BLOB4", name: nil})
      grant(host, "root", %{key_base64: "BLOB5", name: "named in ssm"})

      assert items_of(host) == [
               {:present, "ssh-rsa BLOB4 laptop"},
               {:present, "ssh-rsa BLOB5"}
             ]
    end

    test "a sync keeps the host's line of a granted key (options, comment) and drops the rest" do
      opt_line = ~s(from="10.0.0.0/8",no-pty ssh-rsa BLOB6 laptop)

      host =
        host_with_file(
          "deploy",
          Enum.join([opt_line, "ssh-rsa BLOB7 old-comment", "ssh-rsa GONE x"], "\n")
        )

      grant(host, "deploy", %{key_base64: "BLOB6", name: "laptop"})
      grant(host, "deploy", %{key_base64: "BLOB7", name: "Wim Bonis"})
      grant(host, "deploy", %{key_base64: "NEWKEY", name: "new"})
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert {:ok, [%{login: "deploy", written_keys: 3}]} = Diffs.sync_host(MockClient, host.id)

      {_, _, written} =
        Enum.find(MockClient.calls().exec_inputs, fn {_id, cmd, _} ->
          String.contains?(cmd, "set_authorized_keyfile deploy")
        end)

      lines = String.split(written, "\n", trim: true)
      assert opt_line in lines
      assert "ssh-rsa BLOB7 old-comment" in lines
      # a key the host lacks gets ssm's line
      assert "ssh-rsa NEWKEY new" in lines
      refute Enum.any?(lines, &String.contains?(&1, "GONE"))
      assert length(lines) == 3
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
