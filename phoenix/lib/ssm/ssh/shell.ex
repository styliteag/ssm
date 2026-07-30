defmodule Ssm.Ssh.Shell do
  @moduledoc "POSIX shell quoting — the `shlex.quote` the python stack leaned on."

  @doc """
  Quote a string for safe interpolation into an `sh -c` command line.
  Empty string quotes to `''`; single quotes are closed, escaped, reopened.
  """
  @spec quote(String.t()) :: String.t()
  def quote(""), do: "''"

  def quote(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9@%+=:,.\/_-]+\z/) do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end
end
