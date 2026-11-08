defmodule Ssm.Authorizations.OptionsTest do
  use Ssm.DataCase, async: true

  import Ssm.Fixtures

  alias Ssm.Authorizations
  alias Ssm.Authorizations.Options

  describe "missing_restrictions/2 and weaker?/2" do
    test "restriction entries compare by name and exact value" do
      required = ~s(restrict,No-Pty,from="10.0.0.0/8",verify-required)

      assert Options.missing_restrictions(required, required) == []
      assert Options.missing_restrictions(required, String.downcase(required)) == []

      assert Options.missing_restrictions(required, nil) ==
               ["restrict", "no-pty", ~s(from="10.0.0.0/8"), "verify-required"]

      assert Options.missing_restrictions(required, ~s(restrict,no-pty,from="0.0.0.0/0")) ==
               [~s(from="10.0.0.0/8"), "verify-required"]

      assert Options.missing_restrictions(nil, required) == []
      assert Options.missing_restrictions(~s(environment="A=b",pty), nil) == []
    end

    test "weaker?: lacks a restriction of the other or carries a permissive option it lacks" do
      assert Options.weaker?(nil, "no-pty")
      assert Options.weaker?(~s(from="10.0.0.0/8"), ~s(from="10.0.0.1"))
      assert Options.weaker?("no-pty,agent-forwarding", "no-pty")
      refute Options.weaker?("no-pty", "no-pty")
      refute Options.weaker?("no-pty,no-user-rc", "no-pty")
      refute Options.weaker?("no-pty", nil)
      refute Options.weaker?("no-pty", "agent-forwarding")
    end
  end

  describe "validate/1" do
    test "accepts empty and allow-listed options" do
      for options <- [
            nil,
            "",
            "restrict",
            "no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc",
            ~s(from="10.0.0.0/8,192.0.2.1",command="/usr/bin/backup --run",no-pty),
            ~s(environment="A=b c",expiry-time="20271231",permitopen="localhost:80"),
            ~s(permitlisten="8080",principals="ops",tunnel="1",cert-authority),
            "pty,port-forwarding,agent-forwarding,X11-forwarding,user-rc",
            "no-touch-required,verify-required"
          ] do
        assert Options.validate(options) == :ok, "expected #{inspect(options)} to pass"
      end
    end

    test "rejects option names outside the allow-list" do
      assert {:error, message} = Options.validate("no-pty,bogus")
      assert message =~ ~s(unknown option "bogus")
    end

    test "rejects control characters" do
      for bad <- ["no-pty\nssh-rsa AAAA evil", "no-pty\r", "no-pty\t", "restrict\x00", "pty\x7f"] do
        assert {:error, message} = Options.validate(bad)
        assert message =~ "control characters"
      end
    end

    test "rejects unbalanced quotes" do
      assert {:error, message} = Options.validate(~s(command="/bin/true))
      assert message =~ "unbalanced quotes"
    end

    test "rejects every backslash (sshd only knows \\\" and would end the value elsewhere)" do
      smuggle = ~s(environment="A=b\\\\",from=" ssh-ed25519 AAAAATTACKER z")

      for bad <- [smuggle, ~s(command="echo \\"hi\\""), ~s(command="a\\b")] do
        assert {:error, message} = Options.validate(bad), "expected #{inspect(bad)} to fail"
        assert message =~ "backslash"
      end
    end

    test "flags take no value, valued options need one" do
      assert {:error, message} = Options.validate(~s(no-pty="x"))
      assert message =~ ~s("no-pty" takes no value)
      assert {:error, message} = Options.validate("from")
      assert message =~ ~s("from" needs a value)
      assert {:error, _} = Options.validate("restrict,command")
      assert :ok = Options.validate(~s(restrict,command="/bin/true",tunnel="0"))
    end

    test "rejects unquoted values, empty entries and whitespace outside quotes" do
      assert {:error, _} = Options.validate("from=10.0.0.1")
      assert {:error, _} = Options.validate("no-pty,,restrict")
      assert {:error, _} = Options.validate("no-pty, restrict")
      assert {:error, _} = Options.validate(~s(command="x"y))
    end
  end

  describe "Authorization changeset" do
    test "rejects invalid options with a clear error" do
      assert {:error, changeset} =
               Authorizations.create_authorization(%{
                 user_id: user_fixture().id,
                 host_id: host_fixture().id,
                 login: "deploy",
                 options: "no-pty,evil-option"
               })

      assert %{options: [message]} = errors_on(changeset)
      assert message =~ ~s(unknown option "evil-option")
    end

    test "rejects a newline in the options" do
      assert {:error, changeset} =
               Authorizations.create_authorization(%{
                 user_id: user_fixture().id,
                 host_id: host_fixture().id,
                 login: "deploy",
                 options: "no-pty\nssh-ed25519 AAAAINJECTED evil"
               })

      assert %{options: [_]} = errors_on(changeset)
    end

    test "rejects invalid options on update" do
      auth = authorization_fixture(user_fixture(), host_fixture())
      assert {:error, changeset} = Authorizations.update_authorization(auth, %{options: "x"})
      assert %{options: [_]} = errors_on(changeset)
    end
  end
end
