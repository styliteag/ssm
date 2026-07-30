defmodule Ssm.Ssh.Safety do
  @moduledoc """
  Host-level safety guards before any SSH write — port of ssh/safety.py.

  1. `host.disabled` from the database: checked before opening a connection.
  2. Readonly sentinels on the remote host: `~/.ssh/system_readonly` (global
     for the SSH user) and the login's `~/.ssh/user_readonly`. Non-empty
     contents freeze writes; the contents become the reason shown in the UI.
  """

  alias Ssm.Ssh.{Result, Shell, Target}

  @readonly_script ~S"""
  set -u
  system="$HOME/.ssh/system_readonly"
  if [ -s "$system" ]; then
      printf 'system_readonly: %s\n' "$(cat "$system")"
      exit 0
  fi
  home_dir="$(getent passwd "$1" | cut -d: -f6)"
  if [ -n "$home_dir" ]; then
      user_file="$home_dir/.ssh/user_readonly"
      if [ -s "$user_file" ]; then
          printf 'user_readonly: %s\n' "$(cat "$user_file")"
          exit 0
      fi
  fi
  """

  @doc "Error when the host is disabled; the DB flag is the only source."
  @spec ensure_host_not_disabled(%{disabled: boolean(), name: String.t()}) ::
          :ok | {:error, {:host_disabled, String.t()}}
  def ensure_host_not_disabled(%{disabled: true, name: name}),
    do: {:error, {:host_disabled, "host #{inspect(name)} is disabled"}}

  def ensure_host_not_disabled(_host), do: :ok

  @doc "The readonly reason for `login` on `target`, or nil."
  @spec check_readonly(module(), Target.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def check_readonly(client, target, login) do
    command = "sh -c #{Shell.quote(@readonly_script)} sh #{Shell.quote(login)}"

    with {:ok, %Result{} = result} <- client.exec(target, command, []) do
      case String.trim(result.stdout) do
        "" -> {:ok, nil}
        reason -> {:ok, reason}
      end
    end
  end

  @doc "Error with the readonly reason if either sentinel is set."
  @spec ensure_writable(module(), Target.t(), String.t()) :: :ok | {:error, term()}
  def ensure_writable(client, target, login) do
    case check_readonly(client, target, login) do
      {:ok, nil} ->
        :ok

      {:ok, reason} ->
        {:error,
         {:ssh_readonly,
          "host #{inspect(target.name)} is read-only for #{inspect(login)}: #{reason}"}}

      {:error, _} = error ->
        error
    end
  end
end
