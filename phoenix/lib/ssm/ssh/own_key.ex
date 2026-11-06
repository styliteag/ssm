defmodule Ssm.Ssh.OwnKey do
  @moduledoc """
  ssm's own SSH public key — the key it logs in with (`SSH_KEY`, decrypted
  with `SSH_KEY_PASSPHRASE`). Mission Control installs it on new hosts
  (onboarding v2 §4, `ssm_public_key` in the `create_host` job result).

  The key is always derived from the private key with `ssh-keygen -y`, never
  read from a `.pub` file next to it (a stale one would make every login
  fail). The private key is copied into a private temp file (0600; OpenSSH
  refuses world-readable keys) that is removed again at once.
  """

  require Logger

  @doc """
  `{:ok, "<type> <base64>"}` or `{:error, :ssm_key_unavailable}`.
  Options (tests): `:key_file`, `:key_passphrase`, `:work_dir`; default
  from `config :ssm, :ssh`.
  """
  @spec public_key(keyword()) :: {:ok, String.t()} | {:error, :ssm_key_unavailable}
  def public_key(opts \\ []) do
    config = Application.get_env(:ssm, :ssh, [])
    source = Path.expand(option(opts, config, :key_file, "keys/id_ssm"))
    passphrase = option(opts, config, :key_passphrase, nil) || ""
    work_dir = Keyword.get_lazy(opts, :work_dir, &System.tmp_dir!/0)

    case derive(source, passphrase, work_dir) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("ssh.own_key_unavailable file=#{source} reason=#{inspect(reason)}")
        {:error, :ssm_key_unavailable}
    end
  end

  defp option(opts, config, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Keyword.get(config, key, default) end)

  defp derive(source, passphrase, work_dir) do
    work = Path.join(work_dir, "ssm-own-key-#{System.unique_integer([:positive])}")

    try do
      # 0600 before any key material is written.
      with {:ok, material} <- File.read(source),
           :ok <- File.write(work, "", [:exclusive]),
           :ok <- File.chmod(work, 0o600),
           :ok <- File.write(work, material) do
        keygen_public(work, passphrase)
      end
    after
      File.rm(work)
    end
  end

  defp keygen_public(path, passphrase) do
    case System.cmd("ssh-keygen", ["-y", "-P", passphrase, "-f", path], stderr_to_stdout: true) do
      {out, 0} ->
        case Ssm.Ssh.HostKey.public_key(out) do
          {:ok, _} = ok -> ok
          {:error, _} -> {:error, :unexpected_ssh_keygen_output}
        end

      {_out, status} ->
        {:error, {:ssh_keygen_failed, status}}
    end
  rescue
    e in ErlangError -> {:error, {:ssh_keygen_missing, e.original}}
  end
end
