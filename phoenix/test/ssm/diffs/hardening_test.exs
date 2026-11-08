defmodule Ssm.Diffs.HardeningTest do
  @moduledoc """
  Review findings on the sync engine: host lines that hide a key inside an
  option value, a sync without ssm's own key, readonly logins found only
  after earlier writes, legacy rows with invalid options, and DB options
  that drop restrictions the host line carried.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs
  alias Ssm.Diffs.HostDiff
  alias Ssm.Repo
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @get_keyfiles "sh .ssm/script.sh get_ssh_keyfiles"
  @own Ssm.Test.OwnKeyStub.default()

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp stub_host(host, files) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    entries =
      for file <- files do
        {login, text, readonly, scope} = with_scope(file)

        %{
          login: login,
          has_pragma: true,
          readonly_condition: readonly,
          readonly_scope: scope,
          keyfile: text
        }
      end

    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp with_scope({login, text, nil}), do: {login, text, nil, ""}
  defp with_scope({login, text, readonly}), do: {login, text, readonly, "system"}
  defp with_scope({_login, _text, _readonly, _scope} = file), do: file

  defp writes(host) do
    for {id, cmd, input} <- MockClient.calls().exec_inputs,
        id == host.id,
        [_, login] <- [Regex.run(~r/set_authorized_keyfile (\S+)/, cmd)],
        into: %{},
        do: {login, input}
  end

  defp grant(host, login, base64, options \\ nil) do
    user = user_fixture()
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: base64, name: "laptop"})
    authorization_fixture(user, host, %{login: login, options: options})
  end

  defp items_of(host, login_name) do
    {:ok, %HostDiff{logins: logins}} = Diffs.host_diff(MockClient, host.id)
    login = Enum.find(logins, &(&1.login == login_name))
    Enum.map(login.items, &{&1.status, &1.line, &1.note})
  end

  describe "a granted key hidden inside an option value" do
    @smuggled ~s(environment="X= ssh-ed25519 GRANTED1 " ssh-ed25519 ATTACKER1 z)

    test "is not the granted key: the diff shows it as extra and the key as missing" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "deploy", "GRANTED1")
      stub_host(host, [{"deploy", @smuggled, nil}])

      assert items_of(host, "deploy") == [
               {:missing_on_host, "ssh-ed25519 GRANTED1 laptop", nil},
               {:extra_on_host, @smuggled, nil}
             ]
    end

    test "a sync writes the DB line, never the host line" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "deploy", "GRANTED1")
      stub_host(host, [{"deploy", @smuggled, nil}])

      assert {:ok, _} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => "ssh-ed25519 GRANTED1 laptop\n"}
    end

    test "ssm's own key inside an option value is not ssm's key" do
      host = host_fixture(%{username: "root"})
      line = ~s(environment="X= #{@own} " ssh-ed25519 ATTACKER2 z)
      stub_host(host, [{"root", line, nil}])

      assert items_of(host, "root") == [{:extra_on_host, line, nil}]
    end
  end

  describe "ssm's own key unavailable" do
    setup do
      Application.put_env(:ssm, :test_own_public_key, :unavailable)
      on_exit(fn -> Application.delete_env(:ssm, :test_own_public_key) end)
    end

    test "a sync that would write the host's login user aborts and writes nothing" do
      host = host_fixture(%{username: "root"})
      grant(host, "deploy", "OWNLESS1")
      grant(host, "root", "OWNLESS2")
      stub_host(host, [{"root", "#{@own} ssm", nil}])

      assert {:error, {:own_key_unavailable, message}} = Diffs.sync_host(MockClient, host.id)
      assert message =~ "root"
      assert writes(host) == %{}
    end

    test "a sync that does not touch the login user goes on" do
      host = host_fixture(%{username: "root"})
      grant(host, "deploy", "OWNLESS3")
      stub_host(host, [])

      assert {:ok, [%{login: "deploy"}]} = Diffs.sync_host(MockClient, host.id)
    end
  end

  describe "readonly markers in the listing" do
    test "a host-wide marker (system_readonly) stops the sync before the first write" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "RO1")
      grant(host, "zzz", "RO2")
      stub_host(host, [{"aaa", "", nil}, {"zzz", "", "Global override exists", "system"}])

      assert {:error, {:ssh_readonly, message}} = Diffs.sync_host(MockClient, host.id)
      assert message =~ "zzz"
      assert writes(host) == %{}
    end

    test "a user_readonly login is skipped, every other login is written" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "RO3")
      grant(host, "mmm", "RO4")
      grant(host, "zzz", "RO5")

      stub_host(host, [
        {"aaa", "", nil},
        {"mmm", "", "do not touch", "user"},
        {"zzz", "", nil}
      ])

      assert {:error, {:ssh_readonly, message}} = Diffs.sync_host(MockClient, host.id)
      assert message =~ ~s(skipped "mmm")
      assert message =~ "do not touch"
      assert message =~ "aaa, zzz"
      assert Map.keys(writes(host)) == ["aaa", "zzz"]
    end

    test "a login without a file whose write the script refuses is skipped, the rest written" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "RO7")
      grant(host, "zzz", "RO8")
      stub_host(host, [{"zzz", "", nil}])

      MockClient.set_exec(
        host.id,
        "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin",
        %Result{
          stdout: "Keyfile is readonly, aborting.",
          exit_code: 1
        }
      )

      assert {{:error, {:ssh_readonly, message}}, report} =
               Diffs.sync_host_reported(MockClient, host.id)

      assert message =~ ~s(skipped "aaa")
      assert message =~ "written: zzz"
      assert Enum.map(report.written, & &1.login) == ["zzz"]
      assert [{"aaa", reason}] = report.skipped
      assert reason =~ "readonly"
    end

    test "a user_readonly not owned by root: listed as ignored, written, never blocks" do
      host = host_fixture(%{username: "ssm-admin"})
      auth = grant(host, "deploy", "RO9")
      {:ok, _} = Ssm.Authorizations.delete_authorization(auth)
      payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
      MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

      entry = %{
        login: "deploy",
        has_pragma: true,
        readonly_condition: "",
        readonly_scope: "",
        readonly_ignored: "user_readonly not owned by root",
        keyfile: "ssh-ed25519 RO9 laptop"
      }

      MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!([entry])})
      MockClient.set_default_exec(%Result{exit_code: 0})

      assert items_of(host, "deploy") == [{:extra_on_host, "ssh-ed25519 RO9 laptop", nil}]
      {:ok, diff} = Diffs.host_diff(MockClient, host.id)
      assert [%{readonly_ignored: "user_readonly not owned by root"}] = diff.logins

      assert {{:ok, [%{login: "deploy"}]}, report} =
               Diffs.sync_host_reported(MockClient, host.id)

      assert report.ignored == [{"deploy", "user_readonly not owned by root"}]
      assert writes(host) == %{"deploy" => ""}
    end

    test "a linked authorized_keys is not read but written (the link is replaced)" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "UNS1")
      payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
      MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})
      entries = [%{login: "aaa", unsafe: "symlink", keyfile: ""}]
      MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
      MockClient.set_default_exec(%Result{exit_code: 0})

      {:ok, diff} = Diffs.host_diff(MockClient, host.id)
      [aaa] = diff.logins
      assert aaa.read_error == nil
      assert aaa.unsafe =~ "symlink"
      assert [%{status: :missing_on_host}] = aaa.items

      assert {:ok, [%{login: "aaa"}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"aaa" => "ssh-ed25519 UNS1 laptop\n"}
    end

    test "an unsafe ~/.ssh is skipped and marked revocation blocked" do
      host = host_fixture(%{username: "ssm-admin"})
      auth = grant(host, "aaa", "UNS5")
      {:ok, _} = Ssm.Authorizations.delete_authorization(auth)
      grant(host, "zzz", "UNS2")
      payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
      MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

      entries = [
        %{login: "aaa", unsafe: "ssh_dir", keyfile: ""},
        %{login: "zzz", unsafe: "", keyfile: ""}
      ]

      MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: Jason.encode!(entries)})
      MockClient.set_default_exec(%Result{exit_code: 0})

      {:ok, diff} = Diffs.host_diff(MockClient, host.id)
      aaa = Enum.find(diff.logins, &(&1.login == "aaa"))
      assert aaa.blocked == "revocation blocked: unsafe ~/.ssh"
      # visible through the existing per-login field (API diff JSON too)
      assert aaa.read_error =~ "revocation blocked: unsafe ~/.ssh"
      # the periodic check keeps it as drift with the note, not a host error
      assert Ssm.Diffs.SyncCheck.result(diff, %{}).state == "drift"

      assert Enum.any?(
               Ssm.Diffs.SyncCheck.result(diff, %{}).drift,
               &(&1["login"] == "aaa" and &1["blocked"] == "revocation blocked: unsafe ~/.ssh")
             )

      assert {{:error, {:ssh_readonly, message}}, report} =
               Diffs.sync_host_reported(MockClient, host.id)

      assert message =~ ~s(skipped "aaa")
      assert message =~ "revocation blocked: unsafe ~/.ssh"
      assert Map.keys(writes(host)) == ["zzz"]
      assert [{"aaa", "revocation blocked: unsafe ~/.ssh"}] = report.skipped
    end

    test "a write refused as unsafe (link-to-dir) is a per-login skip with that reason" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "LTD1")
      grant(host, "zzz", "LTD2")
      stub_host(host, [{"aaa", "", nil}, {"zzz", "", nil}])

      MockClient.set_exec(
        host.id,
        "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin",
        %Result{
          stdout: "Keyfile is unsafe (link-to-dir), aborting.",
          exit_code: 1
        }
      )

      assert {{:error, {:ssh_readonly, message}}, report} =
               Diffs.sync_host_reported(MockClient, host.id)

      assert [{"aaa", "unsafe: link-to-dir"}] = report.skipped
      assert message =~ "unsafe: link-to-dir"
      assert Enum.map(report.written, & &1.login) == ["zzz"]
    end

    test "a write the script refuses as unsafe is skipped too" do
      host = host_fixture(%{username: "ssm-admin"})
      grant(host, "aaa", "UNS3")
      grant(host, "zzz", "UNS4")
      stub_host(host, [{"zzz", "", nil}])

      MockClient.set_exec(
        host.id,
        "sh .ssm/script.sh set_authorized_keyfile aaa ssm-admin",
        %Result{
          stdout: "Keyfile is unsafe (ssh_dir), aborting.",
          exit_code: 1
        }
      )

      assert {{:error, {:ssh_readonly, message}}, report} =
               Diffs.sync_host_reported(MockClient, host.id)

      assert message =~ ~s(skipped "aaa")
      assert Enum.map(report.written, & &1.login) == ["zzz"]
    end

    test "pending removals on a user_readonly login are marked in the diff and the check" do
      host = host_fixture(%{username: "ssm-admin"})
      auth = grant(host, "deploy", "RO6")
      {:ok, _} = Ssm.Authorizations.delete_authorization(auth)
      stub_host(host, [{"deploy", "ssh-ed25519 RO6 laptop", "mine", "user"}])

      assert items_of(host, "deploy") == [
               {:extra_on_host, "ssh-ed25519 RO6 laptop", "revocation blocked by user_readonly"}
             ]

      {:ok, diff} = Diffs.host_diff(MockClient, host.id)

      assert [%{"blocked" => "revocation blocked by user_readonly"}] =
               Ssm.Diffs.SyncCheck.result(diff, %{}).drift
    end
  end

  describe "a legacy row with options invalid under the new rules" do
    defp legacy_grant(host, base64, options) do
      user = user_fixture()
      key_fixture(user, %{key_type: "ssh-ed25519", key_base64: base64, name: "laptop"})

      Repo.insert!(%Authorization{
        user_id: user.id,
        host_id: host.id,
        login: "deploy",
        options: options
      })
    end

    test "keeps the host's line of that key and marks it in the diff" do
      host = host_fixture(%{username: "ssm-admin"})
      legacy_grant(host, "LEGACY1", "no-pty,bogus-option")
      line = "no-pty ssh-ed25519 LEGACY1 handmade"
      stub_host(host, [{"deploy", line, nil}])

      assert items_of(host, "deploy") == [{:present, line, "invalid stored options"}]
      assert {:ok, [%{written_keys: 1}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => line <> "\n"}
    end

    test "is skipped when the host lacks the key (never written without its options)" do
      host = host_fixture(%{username: "ssm-admin"})
      legacy_grant(host, "LEGACY2", "bogus-option")
      stub_host(host, [{"deploy", "", nil}])

      assert items_of(host, "deploy") == [
               {:missing_on_host, "ssh-ed25519 LEGACY2 laptop", "invalid stored options"}
             ]

      assert {:ok, [%{written_keys: 0}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => ""}
    end

    test "a legacy key name with a tab or C1 control: the key is written without comment" do
      host = host_fixture(%{username: "ssm-admin", name: "latin-host"})
      user = user_fixture()

      key =
        Repo.insert!(%Ssm.Users.UserKey{
          user_id: user.id,
          key_type: "ssh-ed25519",
          key_base64: "LATIN1",
          name: "J\u0085rgen\tlaptop"
        })

      authorization_fixture(user, host, %{login: "deploy"})
      stub_host(host, [{"deploy", "", nil}])

      assert {:ok, [%{written_keys: 1}]} = Diffs.sync_host(MockClient, host.id)
      assert writes(host) == %{"deploy" => "ssh-ed25519 LATIN1\n"}

      assert Enum.any?(
               Ssm.Release.invalid_stored_rows(),
               &match?(%{table: "user_key", field: "name"}, &1)
             )

      _ = key
    end

    test "the pre-upgrade report lists it" do
      host = host_fixture(%{name: "legacy-host"})
      auth = legacy_grant(host, "LEGACY3", ~s(command="a\\b"))

      assert [
               %{
                 table: "authorization",
                 id: id,
                 field: "options",
                 host: "legacy-host",
                 login: "deploy",
                 reason: reason
               }
             ] = Ssm.Release.invalid_stored_rows()

      assert id == auth.id
      assert reason =~ "backslash"
    end
  end

  test "DB options that drop a host restriction are marked" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "deploy", "RESTR1", "no-pty")
    host_line = ~s(from="192.0.2.1",command="/bin/backup",no-pty ssh-ed25519 RESTR1 laptop)
    stub_host(host, [{"deploy", host_line, nil}])

    assert items_of(host, "deploy") == [
             {:missing_on_host, "no-pty ssh-ed25519 RESTR1 laptop", nil},
             {:extra_on_host, host_line, "drops host restriction: from, command"}
           ]

    assert {:ok, _} = Diffs.sync_host(MockClient, host.id)
    assert writes(host) == %{"deploy" => "no-pty ssh-ed25519 RESTR1 laptop\n"}
  end

  test "a sync never writes a key twice (DB line and legacy host line)" do
    id = {"ssh-ed25519", "TWICE"}

    assert Ssm.Diffs.Compare.lines_to_write(
             ["ssh-ed25519 TWICE a"],
             [%{key_id: 1, id: id, line: "ssh-ed25519 TWICE a"}],
             ["no-pty ssh-ed25519 TWICE b"]
           ) == ["no-pty ssh-ed25519 TWICE b"]
  end

  test "a Latin-1 comment on the host (invalid UTF-8) is no drift for a granted key" do
    host = host_fixture(%{username: "ssm-admin"})
    grant(host, "deploy", "LATIN2")
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    stdout =
      ~s([{"login":"deploy","has_pragma":true,"readonly_condition":"","readonly_scope":"",) <>
        ~s("keyfile":"ssh-ed25519 LATIN2 J) <> <<0xFC>> <> ~s(rgen"}])

    MockClient.set_exec(host.id, @get_keyfiles, %Result{stdout: stdout})

    assert [{:present, line, nil}] = items_of(host, "deploy")
    assert line == "ssh-ed25519 LATIN2 J\uFFFDrgen"
  end
end
