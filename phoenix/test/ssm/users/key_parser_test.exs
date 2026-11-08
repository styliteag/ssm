defmodule Ssm.Users.KeyParserTest do
  use ExUnit.Case, async: true

  alias Ssm.Users.KeyParser

  defp material(type, payload \\ <<1, 2, 3>>) do
    Base.encode64(<<byte_size(type)::32, type::binary>> <> payload)
  end

  test "parses type, material, and comment" do
    base64 = material("ssh-ed25519")

    assert {:ok, %{key_type: "ssh-ed25519", key_base64: ^base64, name: "alice@laptop"}} =
             KeyParser.parse("ssh-ed25519 #{base64} alice@laptop")
  end

  test "comment is optional and trimmed; blank comment becomes nil" do
    base64 = material("ssh-ed25519")

    assert {:ok, %{name: nil}} = KeyParser.parse("ssh-ed25519 #{base64}")
    assert {:ok, %{name: nil}} = KeyParser.parse("ssh-ed25519 #{base64}   ")
    assert {:ok, %{name: "a b"}} = KeyParser.parse("ssh-ed25519 #{base64}  a b ")
  end

  test "surrounding whitespace is tolerated" do
    base64 = material("ssh-rsa")
    assert {:ok, %{key_type: "ssh-rsa"}} = KeyParser.parse("  ssh-rsa #{base64} pc\n")
  end

  test "rejects unsupported key types" do
    assert {:error, message} = KeyParser.parse("ssh-bogus AAAA comment")
    assert message =~ "unsupported key type"
  end

  test "rejects a bare type with no material" do
    assert {:error, "missing base64 key material"} = KeyParser.parse("ssh-ed25519")
  end

  test "rejects material that is not base64" do
    assert {:error, "invalid base64 key material"} =
             KeyParser.parse("ssh-ed25519 not*base64!")
  end

  test "rejects material whose wire type differs from the declared type" do
    rsa_material = material("ssh-rsa")

    assert {:error, message} = KeyParser.parse("ssh-ed25519 #{rsa_material} pc")
    assert message =~ "does not match declared type ssh-ed25519"
  end

  test "rejects material shorter than its own type prefix" do
    assert {:error, message} = KeyParser.parse("ssh-ed25519 AAAA")
    assert message =~ "does not match declared type"
  end

  test "rejects empty and blank lines" do
    assert {:error, "empty line"} = KeyParser.parse("")
    assert {:error, "empty line"} = KeyParser.parse("   ")
  end

  describe "identity/1 (an authorized_keys line's key: type + base64)" do
    test "ignores comment, options prefix, whitespace and CRLF" do
      for line <- [
            "ssh-rsa BLOB",
            "ssh-rsa BLOB Wim Bonis RSA 2022",
            ~s(from="10.0.0.0/8",no-pty ssh-rsa BLOB laptop),
            ~s(command="/bin/true",no-port-forwarding ssh-rsa BLOB),
            "  ssh-rsa   BLOB   laptop  \r"
          ] do
        assert KeyParser.identity(line) == {"ssh-rsa", "BLOB"}, line
      end
    end

    test "nil for a line without a known key type and material" do
      assert KeyParser.identity("") == nil
      assert KeyParser.identity("# comment") == nil
      assert KeyParser.identity("ssh-rsa") == nil
      assert KeyParser.identity("unknown-type BLOB") == nil
    end
  end

  describe "parse_authorized_line/1" do
    test "parses a line with an options prefix like a plain one" do
      base64 = material("ssh-ed25519")

      assert {:ok, %{key_type: "ssh-ed25519", key_base64: ^base64, name: "ot@FW13-OT"}} =
               KeyParser.parse_authorized_line(
                 ~s(no-pty,from="10.0.0.1" ssh-ed25519 #{base64} ot@FW13-OT)
               )

      assert {:ok, %{key_base64: ^base64, name: nil}} =
               KeyParser.parse_authorized_line("ssh-ed25519 #{base64}")
    end

    test "still validates the key material" do
      assert {:error, _} = KeyParser.parse_authorized_line(~s(no-pty ssh-ed25519 NOTBASE64!))
    end
  end
end
