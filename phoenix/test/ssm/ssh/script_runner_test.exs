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
    test "JSON escapes decode as they are: a backslash in a host line stays a backslash" do
      stub_version_current()

      text = ~S(command="printf a\nb" ssh-ed25519 AAAA one) <> "\n" <> ~S(ssh-rsa BBBB C:\x)
      json = Jason.encode!([%{login: "deploy", has_pragma: true, keyfile: text}])
      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})

      assert {:ok, [deploy]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert deploy.keyfile == text
    end

    test "script.sh json_escape: backslash, quote, tab, CR, other C0, lines joined by \\n" do
      [function] = Regex.run(~r/^json_escape\(\) \{.*?^\}/ms, ScriptRunner.script_source())
      input = ~S(a\"b) <> "\r\n" <> ~S(c\nd "e") <> "\t\x01\x1f"
      script = function <> "\nprintf '%s' \"$1\" | json_escape"

      {out, 0} = System.cmd("sh", ["-c", script, "sh", input])

      assert Jason.decode!(~s(") <> out <> ~s(")) == input
    end

    @tag :tmp_dir
    test "the real script.sh emits valid JSON for tabs, quotes, backslashes and newlines",
         %{tmp_dir: dir} do
      script = Path.join(dir, "script.sh")
      File.write!(script, ScriptRunner.script_source())
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      users = [{"tabby", "h1"}, {~s(we"ird), "h2"}, {"locked", "h3"}]

      passwd =
        Enum.map_join(users, "", fn {name, home} ->
          File.mkdir_p!(Path.join([dir, home, ".ssh"]))
          "#{name}:x:1000:1000::#{Path.join(dir, home)}:/bin/sh\n"
        end)

      File.write!(Path.join(dir, "passwd"), passwd)

      File.write!(Path.join(bin, "getent"), """
      #!/bin/sh
      if [ -n "$2" ]; then grep "^$2:" "#{dir}/passwd"; else cat "#{dir}/passwd"; fi
      """)

      File.chmod!(Path.join(bin, "getent"), 0o755)
      File.write!(Path.join(dir, "h1/.ssh/authorized_keys"), "no-pty\tssh-ed25519 AAAA tab\n")
      File.write!(Path.join(dir, "h2/.ssh/authorized_keys"), "ssh-rsa BBBB q\n")
      File.write!(Path.join(dir, "h3/.ssh/authorized_keys"), "ssh-rsa CCCC c\n")
      File.write!(Path.join(dir, "h3/.ssh/user_readonly"), ~S(mine "x" \y) <> "\nline2\x01")
      File.mkdir_p!(Path.join(dir, "home/.ssh"))

      env = [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"HOME", Path.join(dir, "home")},
        {"TMPDIR", dir}
      ]

      {out, 0} = System.cmd("sh", [script, "get_ssh_keyfiles"], env: env)
      entries = out |> Jason.decode!() |> Map.new(&{&1["login"], &1})

      assert entries["tabby"]["keyfile"] =~ "no-pty\tssh-ed25519 AAAA tab"
      assert entries[~s(we"ird)]["keyfile"] =~ "ssh-rsa BBBB q"
      # the marker's content is never shown, only a fixed reason
      assert entries["locked"]["readonly_condition"] == "user_readonly (root-owned)"
      assert entries["locked"]["readonly_scope"] == "user"
      assert entries["tabby"]["readonly_scope"] == ""
    end

    # lab-deb12 (mawk): a 0xFF byte in a key comment or in user_readonly
    @tag :tmp_dir
    test "a 0xFF byte from the real script (mawk) survives the SSH client and the parser",
         %{tmp_dir: dir} do
      {awk, 0} = System.cmd("sh", ["-c", "readlink -f \"$(command -v awk)\""])
      assert awk =~ "mawk", "the test image should run script.sh with mawk"

      script = Path.join(dir, "script.sh")
      File.write!(script, ScriptRunner.script_source())
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      passwd =
        Enum.map_join([{"ff", "h1"}, {"ro", "h2"}], "", fn {name, home} ->
          File.mkdir_p!(Path.join([dir, home, ".ssh"]))
          "#{name}:x:1000:1000::#{Path.join(dir, home)}:/bin/sh\n"
        end)

      File.write!(Path.join(dir, "passwd"), passwd)

      File.write!(Path.join(bin, "getent"), """
      #!/bin/sh
      if [ -n "$2" ]; then grep "^$2:" "#{dir}/passwd"; else cat "#{dir}/passwd"; fi
      """)

      File.chmod!(Path.join(bin, "getent"), 0o755)
      File.write!(Path.join(dir, "h1/.ssh/authorized_keys"), "ssh-ed25519 AAAA J\xFFrgen\n")
      File.write!(Path.join(dir, "h2/.ssh/authorized_keys"), "ssh-rsa BBBB a\nssh-rsa CCCC b\n")
      File.write!(Path.join(dir, "h2/.ssh/user_readonly"), "mine \xFF")
      File.mkdir_p!(Path.join(dir, "home/.ssh"))

      env = [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"HOME", Path.join(dir, "home")},
        {"TMPDIR", dir}
      ]

      {raw, 0} = System.cmd("sh", [script, "get_ssh_keyfiles"], env: env)
      refute String.valid?(raw)

      stub_version_current()
      stdout = Ssm.Ssh.ErlangClient.output_to_string(raw)
      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: stdout})

      assert {:ok, [ff, ro]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert ff.keyfile =~ "ssh-ed25519 AAAA J\uFFFDrgen"
      assert ro.readonly_condition == "user_readonly (root-owned)"
      assert ro.readonly_scope == :user
      assert ro.keyfile =~ "ssh-rsa BBBB a\nssh-rsa CCCC b"
    end

    # only a root-owned user_readonly freezes a login (the login's user can
    # write their own ~/.ssh and must not be able to block revocation)
    test "the real script.sh honours user_readonly only when root owns it" do
      # outside the bind-mounted project: chown must take effect there
      dir = Path.join(System.tmp_dir!(), "ssm-ro-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      script = Path.join(dir, "script.sh")
      File.write!(script, ScriptRunner.script_source())
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      passwd =
        Enum.map_join([{"rootro", "h1"}, {"selfro", "h2"}], "", fn {name, home} ->
          File.mkdir_p!(Path.join([dir, home, ".ssh"]))
          File.write!(Path.join([dir, home, ".ssh", "authorized_keys"]), "ssh-rsa OLD x\n")
          File.write!(Path.join([dir, home, ".ssh", "user_readonly"]), "frozen by #{name}")
          "#{name}:x:1000:1000::#{Path.join(dir, home)}:/bin/sh\n"
        end)

      {_, 0} = System.cmd("chown", ["1000", Path.join(dir, "h2/.ssh/user_readonly")])
      root = "root:x:0:0::#{Path.join(dir, "home")}:/bin/sh\n"
      File.write!(Path.join(dir, "passwd"), root <> passwd)

      File.write!(Path.join(bin, "getent"), """
      #!/bin/sh
      if [ -n "$2" ]; then grep "^$2:" "#{dir}/passwd"; else cat "#{dir}/passwd"; fi
      """)

      File.chmod!(Path.join(bin, "getent"), 0o755)
      File.mkdir_p!(Path.join(dir, "home/.ssh"))

      env = [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"HOME", Path.join(dir, "home")},
        {"TMPDIR", dir}
      ]

      {out, 0} = System.cmd("sh", [script, "get_ssh_keyfiles"], env: env)
      entries = out |> Jason.decode!() |> Map.new(&{&1["login"], &1})

      assert %{"readonly_condition" => "user_readonly (root-owned)", "readonly_scope" => "user"} =
               entries["rootro"]

      assert entries["rootro"]["readonly_ignored"] == ""

      assert %{"readonly_condition" => "", "readonly_scope" => ""} = entries["selfro"]
      assert entries["selfro"]["readonly_ignored"] == "user_readonly not owned by root"

      write = fn login ->
        File.write!(Path.join(dir, "in"), "ssh-rsa NEW y\n")

        System.cmd(
          "sh",
          [
            "-c",
            ~s(sh "$0" set_authorized_keyfile "$1" root < "$2"),
            script,
            login,
            Path.join(dir, "in")
          ],
          env: env
        )
      end

      assert {_, 1} = write.("rootro")
      assert {_, 0} = write.("selfro")
      assert File.read!(Path.join(dir, "h2/.ssh/authorized_keys")) =~ "ssh-rsa NEW y"
      assert File.read!(Path.join(dir, "h1/.ssh/authorized_keys")) == "ssh-rsa OLD x\n"
    end

    test "unsafe is parsed (nil when empty)" do
      stub_version_current()

      json =
        Jason.encode!([
          %{login: "a", unsafe: "symlink", keyfile: ""},
          %{login: "b", unsafe: "", keyfile: "ssh-rsa X y"}
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})
      assert {:ok, [a, b]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert a.unsafe == "symlink"
      assert b.unsafe == nil
    end

    test "the write names the SSH user, so the script refuses a login sharing its home" do
      stub_version_current()

      assert :ok = ScriptRunner.set_authorized_keyfile(MockClient, target(), "toor", "")

      assert {7, "#{@remote} set_authorized_keyfile toor root", ""} in MockClient.calls().exec_inputs
    end

    test "sha256 is parsed only as 64 hex digits" do
      stub_version_current()
      sha = String.duplicate("0f", 32)

      json =
        Jason.encode!([
          %{login: "a", sha256: sha, keyfile: ""},
          %{login: "b", sha256: "x; rm -rf /", keyfile: ""},
          %{login: "c", keyfile: ""}
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})
      assert {:ok, [a, b, c]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert {a.sha256, b.sha256, c.sha256} == {sha, nil, nil}
    end

    test "the write passes a valid expected sha256 and maps a stale refusal" do
      stub_version_current()
      sha = String.duplicate("0f", 32)
      command = "#{@remote} set_authorized_keyfile deploy root #{sha}"

      MockClient.set_exec(7, command, %Result{
        stdout: "Keyfile changed since it was read (stale), aborting.",
        exit_code: 1
      })

      assert {:error, {:ssh_stale, _}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "",
                 expected_sha256: sha
               )

      assert :ok =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "",
                 expected_sha256: "not-a-sha"
               )

      assert {7, "#{@remote} set_authorized_keyfile deploy root", ""} in MockClient.calls().exec_inputs
    end

    test "a target without SSH user is refused before any SSH" do
      for username <- [nil, ""] do
        assert {:error, {:ssh_unsafe, message}} =
                 ScriptRunner.set_authorized_keyfile(
                   MockClient,
                   %{target() | username: username},
                   "deploy",
                   ""
                 )

        assert message =~ "SSH user"
      end

      assert MockClient.calls().exec == []
    end

    test "an unsafe refusal surfaces as ssh_unsafe" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy root", %Result{
        stdout: "Keyfile is unsafe (hardlink), aborting.",
        exit_code: 1
      })

      assert {:error, {:ssh_unsafe, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "")

      assert message =~ "unsafe (hardlink)"
    end

    test "login noise on stderr does not hide the script's refusal" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy root", %Result{
        stdout: "Keyfile is unsafe (hardlink), aborting.",
        stderr: "Found yubikey-agent socket: SSH_AUTH_SOCK=/run/yubikey-agent/a.sock",
        exit_code: 1
      })

      assert {:error, {:ssh_unsafe, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "")

      assert message =~ "unsafe (hardlink)"
      assert message =~ "yubikey-agent"
    end

    test "readonly_ignored is parsed (nil when empty)" do
      stub_version_current()

      json =
        Jason.encode!([
          %{login: "a", readonly_ignored: "user_readonly not owned by root", keyfile: ""},
          %{login: "b", readonly_ignored: "", keyfile: ""}
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})
      assert {:ok, [a, b]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert a.readonly_ignored == "user_readonly not owned by root"
      assert a.readonly_scope == nil
      assert b.readonly_ignored == nil
    end

    test "ErlangClient output: valid UTF-8 unchanged, invalid bytes replaced, never inspected" do
      assert Ssm.Ssh.ErlangClient.output_to_string("plain ü") == "plain ü"
      assert Ssm.Ssh.ErlangClient.output_to_string(<<"[", 0xFF, "]">>) == "[\uFFFD]"
      assert Ssm.Ssh.ErlangClient.output_to_string(~c"chars") == "chars"
    end

    test "invalid UTF-8 inside a string (Latin-1 comment, stray 0xFF) does not fail the read" do
      stub_version_current()

      stdout =
        ~s([{"login":"deploy","has_pragma":true,"readonly_condition":"x) <>
          <<0xFF>> <>
          ~s(","readonly_scope":"user","keyfile":"ssh-rsa AAAA J) <> <<0xFC>> <> ~s(rgen"}])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: stdout})

      assert {:ok, [entry]} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert entry.keyfile == "ssh-rsa AAAA J\uFFFDrgen"
      assert entry.readonly_condition == "x\uFFFD"
    end

    test "script.sh checks readonly conditions in the order system, platform, user" do
      source = ScriptRunner.script_source()

      for function <- ["check_keyfile_condition", "keyfile_condition_scope"] do
        [body] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, source)
        system = :binary.match(body, "system_readonly") |> elem(0)
        platform = :binary.match(body, "platform_condition") |> elem(0)
        user = :binary.match(body, "user_readonly") |> elem(0)
        assert system < platform and platform < user, function
      end
    end

    test "readonly_scope: user is login-local, anything else host-wide" do
      stub_version_current()

      json =
        Jason.encode!([
          %{login: "a", readonly_condition: "x", readonly_scope: "user", keyfile: ""},
          %{login: "b", readonly_condition: "y", readonly_scope: "system", keyfile: ""},
          %{login: "c", readonly_condition: "z", keyfile: ""},
          %{login: "d", readonly_condition: "", readonly_scope: "", keyfile: ""}
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})
      assert {:ok, entries} = ScriptRunner.get_ssh_keyfiles(MockClient, target())
      assert Enum.map(entries, & &1.readonly_scope) == [:user, :host, :host, nil]
    end

    test "parses the JSON list" do
      stub_version_current()

      json =
        Jason.encode!([
          %{
            login: "deploy",
            has_pragma: true,
            readonly_condition: "",
            keyfile: "ssh-ed25519 AAAA one\nssh-rsa BBBB two"
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

  describe "get_ssh_keyfiles/2 entry shape" do
    test "entries of the wrong shape or with an unusable login are dropped" do
      stub_version_current()

      good = %{login: "deploy", has_pragma: false, keyfile: "ssh-ed25519 AAAA x"}

      json =
        Jason.encode!([
          good,
          "deploy",
          [1, 2],
          %{login: 0, has_pragma: false, keyfile: ""},
          %{login: "0", has_pragma: false, keyfile: "root's keys"},
          %{login: "-x", has_pragma: false, keyfile: ""},
          %{login: "+0", has_pragma: false, keyfile: ""},
          %{login: "a/b", has_pragma: false, keyfile: ""},
          %{login: "evil", has_pragma: "yes", keyfile: ""},
          %{login: "evil2", has_pragma: false, keyfile: %{}},
          %{login: "evil3", has_pragma: false, keyfile: "", readonly_condition: [1]},
          %{has_pragma: false, keyfile: ""}
        ])

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})

      assert {:ok, [%LoginKeyfile{login: "deploy"}]} =
               ScriptRunner.get_ssh_keyfiles(MockClient, target())
    end

    test "a host name outside today's login rule (winbind DOMAIN\\user) is still listed" do
      stub_version_current()
      json = Jason.encode!([%{login: "CORP\\jdoe", has_pragma: false, keyfile: ""}])
      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{stdout: json})

      assert {:ok, [%LoginKeyfile{login: "CORP\\jdoe"}]} =
               ScriptRunner.get_ssh_keyfiles(MockClient, target())
    end
  end

  describe "remote output in messages" do
    test "a huge stderr is capped in the error message" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy root", %Result{
        stderr: String.duplicate("x", 100_000),
        exit_code: 1
      })

      assert {:error, {:ssh_connect_failed, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "keys")

      assert String.length(message) < 1_000

      MockClient.set_exec(7, "#{@remote} get_ssh_keyfiles", %Result{
        stderr: String.duplicate("y", 100_000),
        exit_code: 2
      })

      assert {:error, {:ssh_connect_failed, message}} =
               ScriptRunner.get_ssh_keyfiles(MockClient, target())

      assert String.length(message) < 1_000
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

      assert command == "#{@remote} set_authorized_keyfile deploy root"
    end

    test "a readonly refusal surfaces as ssh_readonly" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy root", %Result{
        stderr: "refusing write: readonly (system_readonly set)",
        exit_code: 1
      })

      assert {:error, {:ssh_readonly, message}} =
               ScriptRunner.set_authorized_keyfile(MockClient, target(), "deploy", "keys")

      assert message =~ "system_readonly"
    end

    test "other failures surface as ssh_connect_failed" do
      stub_version_current()

      MockClient.set_exec(7, "#{@remote} set_authorized_keyfile deploy root", %Result{
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
