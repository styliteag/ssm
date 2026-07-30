defmodule Ssm.Ssh.RemoteFile do
  @moduledoc "Contents of a remote file with a best-effort mtime for cache keys."

  @enforce_keys [:content]
  defstruct [:content, :mtime]

  @type t :: %__MODULE__{content: String.t(), mtime: integer() | nil}
end
