defmodule Ssm.ControlCharsTest do
  @moduledoc """
  A newline (or any control character) in text that ends up in an
  authorized_keys line would inject a second line on the host. Changesets
  refuse them; the key parser refuses a multi-line single key.
  """

  use Ssm.DataCase

  import Ssm.Fixtures

  alias Ssm.{Authorizations, Users}
  alias Ssm.Users.KeyParser

  @injected "laptop\nssh-ed25519 AAAAINJECTED evil"

  test "UserKey refuses control characters in name and extra_comment" do
    user = user_fixture()
    base = %{user_id: user.id, key_type: "ssh-ed25519", key_base64: "AAAACTRL1"}

    assert {:error, cs} = Users.create_key(Map.put(base, :name, @injected))
    assert %{name: ["must not contain control characters"]} = errors_on(cs)

    assert {:error, cs} = Users.create_key(Map.put(base, :extra_comment, "a\tb"))
    assert %{extra_comment: [_]} = errors_on(cs)

    key = key_fixture(user)
    assert {:error, cs} = Users.update_key(key, %{name: "x\ry"})
    assert %{name: [_]} = errors_on(cs)
  end

  test "User refuses control characters in the username" do
    assert {:error, cs} = Users.create_user(%{username: "bob\n"})
    assert %{username: ["must not contain control characters"]} = errors_on(cs)
    assert {:error, cs} = Users.create_user(%{username: "bob\x7f"})
    assert %{username: [_]} = errors_on(cs)
  end

  test "Authorization refuses control characters in login and comment" do
    attrs = %{user_id: user_fixture().id, host_id: host_fixture().id, login: "deploy"}

    assert {:error, cs} = Authorizations.create_authorization(%{attrs | login: "deploy\nroot"})
    assert %{login: [_]} = errors_on(cs)

    assert {:error, cs} = Authorizations.create_authorization(Map.put(attrs, :comment, "a\u0000"))
    assert %{comment: [_]} = errors_on(cs)
  end

  test "KeyParser refuses a single key with an inner newline" do
    type = "ssh-ed25519"
    base64 = Base.encode64(<<byte_size(type)::32, type::binary, 1, 2, 3>>)

    assert {:error, message} = KeyParser.parse("#{type} #{base64} #{@injected}")
    assert message =~ "one line"
    assert {:error, _} = KeyParser.parse("#{type} #{base64} a\rb")
    # a trailing newline (pasted line) is still fine
    assert {:ok, %{name: "pc"}} = KeyParser.parse("#{type} #{base64} pc\r\n")
  end

  describe "Unicode line and direction controls" do
    test "are refused like ASCII control characters" do
      for bad <- ["a\u0085b", "a\u2028b", "a\u2029b", "a\u202Eb", "a\u2066b", "a\uFEFFb"] do
        assert Ssm.ControlChars.present?(bad), inspect(bad)
      end

      refute Ssm.ControlChars.present?("Jürgen Müller ü@ä — ok")
    end

    test "invalid UTF-8 counts as present (fails closed)" do
      assert Ssm.ControlChars.present?(<<"a", 0xFF, "b">>)
    end

    test "user comment, host name and host username refuse them" do
      assert {:error, cs} = Users.create_user(%{username: "ok", comment: "a\u202Eb"})
      assert %{comment: [_]} = errors_on(cs)

      base = %{name: "h1", username: "root", address: "10.9.9.9", port: 22}
      assert {:error, cs} = Ssm.Hosts.create_host(%{base | name: "h\u2028x"})
      assert %{name: [_]} = errors_on(cs)
      assert {:error, cs} = Ssm.Hosts.create_host(%{base | username: "ro\not"})
      assert %{username: [_ | _]} = errors_on(cs)
    end
  end
end
