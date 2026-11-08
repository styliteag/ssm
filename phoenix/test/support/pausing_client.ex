defmodule Ssm.Test.PausingClient do
  @moduledoc """
  `Ssm.Ssh.MockClient`, but the `pause_at`-th `authorized_keys` write
  pauses until the test sends `:go` — a sync is caught half-way, after the
  earlier logins were written. `setup/2` installs it as the SSH client
  (`config :ssm, :ssh_client`) for one `async: false` test; the paused
  process sends `{:paused, pid}` to the test.
  """

  alias Ssm.Ssh.MockClient

  @doc "Install for the calling test; restored on exit."
  def setup(test_pid, pause_at) do
    previous = Application.get_env(:ssm, :ssh_client)
    counter = :counters.new(1, [])
    :persistent_term.put({__MODULE__, :config}, {test_pid, pause_at, counter})
    Application.put_env(:ssm, :ssh_client, __MODULE__)

    fn ->
      Application.put_env(:ssm, :ssh_client, previous)
      :persistent_term.erase({__MODULE__, :config})
    end
  end

  def connect(target), do: MockClient.connect(target)
  def read_file(target, path), do: MockClient.read_file(target, path)
  def write_file(target, path, content), do: MockClient.write_file(target, path, content)
  def probe_host_key(target, opts), do: MockClient.probe_host_key(target, opts)
  def close, do: MockClient.close()

  def exec(target, command, opts \\ []) do
    if String.contains?(command, "set_authorized_keyfile"), do: maybe_pause()
    MockClient.exec(target, command, opts)
  end

  defp maybe_pause do
    {test_pid, pause_at, counter} = :persistent_term.get({__MODULE__, :config})
    :counters.add(counter, 1, 1)

    if :counters.get(counter, 1) == pause_at do
      send(test_pid, {:paused, self()})
      receive do: (:go -> :ok)
    end
  end
end
