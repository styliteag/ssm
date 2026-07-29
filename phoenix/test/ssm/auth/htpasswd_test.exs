defmodule Ssm.Auth.HtpasswdTest do
  use ExUnit.Case, async: true

  alias Ssm.Auth.Htpasswd

  @moduletag :tmp_dir

  defp write_htpasswd!(dir, lines) do
    path = Path.join(dir, ".htpasswd")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  describe "verify_password/2" do
    test "accepts a matching $2b$ hash" do
      hash = Bcrypt.hash_pwd_salt("s3cret")
      assert Htpasswd.verify_password("s3cret", hash)
      refute Htpasswd.verify_password("wrong", hash)
    end

    test "normalizes the Apache $2y$ variant" do
      "$2b$" <> rest = Bcrypt.hash_pwd_salt("s3cret")
      assert Htpasswd.verify_password("s3cret", "$2y$" <> rest)
    end

    test "rejects non-bcrypt hashes outright" do
      # apr1 (Apache MD5) and SHA formats must never authenticate.
      refute Htpasswd.verify_password("secret", "$apr1$abcdefgh$0123456789abcdefghijk")
      refute Htpasswd.verify_password("secret", "{SHA}2aae6c35c94fcfb415dbe95f408b9ce91ee846ed")
      refute Htpasswd.verify_password("secret", "plaintext")
    end

    test "malformed bcrypt-prefixed values yield false, not an exception" do
      refute Htpasswd.verify_password("secret", "$2b$not-a-real-hash")
    end

    test "empty inputs are false" do
      refute Htpasswd.verify_password("", Bcrypt.hash_pwd_salt("x"))
      refute Htpasswd.verify_password("x", "")
    end
  end

  describe "parse/1" do
    test "reads entries, skips comments, blanks and malformed lines", %{tmp_dir: dir} do
      path =
        write_htpasswd!(dir, [
          "# a comment",
          "",
          "admin:$2b$04$abcdefghijklmnopqrstuv",
          "no-colon-line",
          ":empty-user",
          "empty-hash:",
          "  spaced  :  $2y$04$zyxw  "
        ])

      entries = Htpasswd.parse(path)
      assert entries == %{"admin" => "$2b$04$abcdefghijklmnopqrstuv", "spaced" => "$2y$04$zyxw"}
    end

    test "missing file yields an empty map" do
      assert Htpasswd.parse("/nonexistent/.htpasswd") == %{}
    end
  end

  describe "verify/3" do
    test "verifies a real entry and rejects unknown users", %{tmp_dir: dir} do
      path = write_htpasswd!(dir, ["admin:" <> Bcrypt.hash_pwd_salt("s3cret")])

      assert Htpasswd.verify(path, "admin", "s3cret")
      refute Htpasswd.verify(path, "admin", "nope")
      refute Htpasswd.verify(path, "ghost", "s3cret")
    end
  end

  describe "entry_fingerprint/2" do
    test "changes when the hash changes, :error when the user is gone", %{tmp_dir: dir} do
      path = write_htpasswd!(dir, ["admin:" <> Bcrypt.hash_pwd_salt("one")])
      {:ok, fp1} = Htpasswd.entry_fingerprint(path, "admin")

      File.write!(path, "admin:" <> Bcrypt.hash_pwd_salt("two") <> "\n")
      {:ok, fp2} = Htpasswd.entry_fingerprint(path, "admin")

      assert fp1 != fp2
      assert Htpasswd.entry_fingerprint(path, "ghost") == :error
    end
  end
end
