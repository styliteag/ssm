defmodule Ssm.Ssh.ErlangClientKeyReloadTest do
  @moduledoc """
  A key created or replaced after boot is picked up on the next connect;
  no restart needed (lab bug: auth_failed until restart).
  """

  use ExUnit.Case, async: false

  alias Ssm.Ssh.{ErlangClient, Target}

  @moduletag :tmp_dir

  defp key_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp target do
    %Target{
      host_id: 1,
      name: "h1",
      address: "127.0.0.1",
      port: 22,
      username: "root",
      host_key_fingerprint: nil
    }
  end

  defp key_dir_now do
    {:connect, key_dir, _, _, _} =
      GenServer.call(ErlangClient, {:probe_spec, target()})

    key_dir
  end

  test "key created after boot is available on the next connect", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "id_ssm")
    start_supervised!({ErlangClient, key_file: source})

    refute File.exists?(Path.join(key_dir_now(), "id_rsa"))

    File.write!(source, key_pem())

    assert File.read!(Path.join(key_dir_now(), "id_rsa")) == File.read!(source)
  end

  test "replaced key is copied over; unchanged key is not rewritten", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "id_ssm")
    File.write!(source, key_pem())
    start_supervised!({ErlangClient, key_file: source})

    dest = Path.join(key_dir_now(), "id_rsa")
    first = File.read!(dest)
    assert first == File.read!(source)
    assert {:ok, %{mtime: m1}} = File.stat(dest, time: :posix)
    assert File.read!(Path.join(key_dir_now(), "id_rsa")) == first
    assert {:ok, %{mtime: ^m1}} = File.stat(dest, time: :posix)

    replacement = key_pem()
    File.write!(source, replacement)
    assert File.read!(Path.join(key_dir_now(), "id_rsa")) == replacement
  end

  test "removed key file keeps the last working key", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "id_ssm")
    File.write!(source, key_pem())
    start_supervised!({ErlangClient, key_file: source})
    first = File.read!(Path.join(key_dir_now(), "id_rsa"))

    File.rm!(source)

    assert File.read!(Path.join(key_dir_now(), "id_rsa")) == first
  end
end
