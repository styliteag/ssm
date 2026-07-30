defmodule Ssm.Ssh.Client do
  @moduledoc """
  Minimal SSH surface the rest of the app talks to — the Elixir analogue of
  the `SshClient` Protocol in backend/src/ssm/ssh/protocol.py. Concrete
  implementations: `Ssm.Ssh.ErlangClient` (production), `Ssm.Ssh.MockClient`
  (tests), `Ssm.Ssh.Cache` (memoising wrapper). Routers/LiveViews never name
  an implementation — they go through the `Ssm.Ssh` facade.

  Errors are tagged tuples, not exceptions; `{:error, {:ssh_connect_failed,
  reason}}` is the moral equivalent of the python `SshConnectFailed`.
  """

  alias Ssm.Ssh.{RemoteFile, Result, Target}

  @type error :: {:error, {:ssh_connect_failed, String.t()}}

  @doc "Ensure a connection to the target exists; idempotent."
  @callback connect(Target.t()) :: :ok | error

  @doc """
  Run a command; `opts[:input]` is piped to the remote stdin (the channel
  ScriptRunner uses to hand authorized_keys content to script.sh).
  """
  @callback exec(Target.t(), String.t(), keyword()) :: {:ok, Result.t()} | error

  @doc "Read a UTF-8 text file."
  @callback read_file(Target.t(), String.t()) :: {:ok, RemoteFile.t()} | error

  @doc "Write content to a path."
  @callback write_file(Target.t(), String.t(), String.t()) :: :ok | error

  @doc "Close every connection this client owns."
  @callback close() :: :ok
end
