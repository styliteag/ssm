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
end
