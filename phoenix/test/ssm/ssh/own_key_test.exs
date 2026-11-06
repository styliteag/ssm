defmodule Ssm.Ssh.OwnKeyTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.OwnKey

  @moduletag :tmp_dir

  defp keygen(dir, name, passphrase) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "ssh-keygen",
        ["-q", "-t", "ed25519", "-N", passphrase, "-C", "ssm@test", "-f", path],
        stderr_to_stdout: true
      )

    # Keys mounted into the container are often world-readable.
    File.chmod!(path, 0o644)
    {path, path |> Kernel.<>(".pub") |> File.read!() |> normalized()}
  end

  defp normalized(line) do
    [type, blob | _] = String.split(line)
    "#{type} #{blob}"
  end

  test "derives the public key (type and base64, no comment) from SSH_KEY", %{tmp_dir: dir} do
    {path, expected} = keygen(dir, "id_plain", "")
    assert OwnKey.public_key(key_file: path) == {:ok, expected}
  end

  test "decrypts a passphrase-protected key", %{tmp_dir: dir} do
    {path, expected} = keygen(dir, "id_enc", "s3cret-pass")
    assert OwnKey.public_key(key_file: path, key_passphrase: "s3cret-pass") == {:ok, expected}

    assert OwnKey.public_key(key_file: path, key_passphrase: "wrong") ==
             {:error, :ssm_key_unavailable}
  end

  test "ignores a stale .pub next to the key", %{tmp_dir: dir} do
    {path, expected} = keygen(dir, "id_a", "")
    {_other, stale} = keygen(dir, "id_b", "")
    File.write!(path <> ".pub", stale <> " stale\n")
    assert OwnKey.public_key(key_file: path) == {:ok, expected}
  end

  test "a missing or unreadable key is ssm_key_unavailable", %{tmp_dir: dir} do
    assert OwnKey.public_key(key_file: Path.join(dir, "nope")) == {:error, :ssm_key_unavailable}
    File.write!(Path.join(dir, "junk"), "not a key\n")
    assert OwnKey.public_key(key_file: Path.join(dir, "junk")) == {:error, :ssm_key_unavailable}
  end

  test "leaves no decrypted copy behind", %{tmp_dir: dir} do
    {path, _} = keygen(dir, "id_c", "")
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {:ok, _} = OwnKey.public_key(key_file: path, work_dir: work)
    assert File.ls!(work) == []
  end
end
