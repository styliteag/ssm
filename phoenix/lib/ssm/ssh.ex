defmodule Ssm.Ssh do
  @moduledoc """
  Facade in front of the configured `Ssm.Ssh.Client` implementation.
  Production wires `Ssm.Ssh.Cache` (which wraps `Ssm.Ssh.ErlangClient`);
  tests set `config :ssm, :ssh_client, Ssm.Ssh.MockClient`.
  """

  @behaviour Ssm.Ssh.Client

  @impl true
  def connect(target), do: impl().connect(target)

  @impl true
  def exec(target, command, opts \\ []), do: impl().exec(target, command, opts)

  @impl true
  def read_file(target, path), do: impl().read_file(target, path)

  @impl true
  def write_file(target, path, content), do: impl().write_file(target, path, content)

  @impl true
  def close, do: impl().close()

  defp impl, do: Application.get_env(:ssm, :ssh_client, Ssm.Ssh.Cache)
end
