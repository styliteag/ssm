defmodule Ssm.Ssh.Result do
  @moduledoc "Outcome of a remote command (`SshResult` in the python stack)."

  defstruct stdout: "", stderr: "", exit_code: 0

  @type t :: %__MODULE__{stdout: String.t(), stderr: String.t(), exit_code: integer()}

  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{exit_code: 0}), do: true
  def ok?(%__MODULE__{}), do: false
end
