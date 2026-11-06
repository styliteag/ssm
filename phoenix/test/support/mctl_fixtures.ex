defmodule Ssm.MctlFixtures do
  @moduledoc "Fixtures for `MctlContract.ConformanceCase` against ssm's endpoint."

  @behaviour MctlContract.ConformanceCase.Fixtures

  alias Ecto.Adapters.SQL.Sandbox

  @host_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"

  @impl true
  def setup(_context) do
    pid = Sandbox.start_owner!(Ssm.Repo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)
    # Per-IP auth failure counters are global; every test starts clean.
    Ssm.RateLimit.reset()
    ExUnit.Callbacks.start_supervised!(Ssm.Ssh.MockClient)
    Ssm.Ssh.MockClient.set_default_host_keys([@host_key])
    :ok
  end

  @impl true
  def token(scopes) do
    name = "conformance-#{System.unique_integer([:positive])}"
    {:ok, _token, plain} = MctlContract.Tokens.Ecto.create(name, scopes, prefix: "ssm_")
    plain
  end

  @impl true
  def valid_host_params do
    n = System.unique_integer([:positive])

    %{
      "addresses" => ["10.#{rem(div(n, 250), 250)}.#{rem(n, 250)}.1"],
      "mode" => "pull",
      "attributes" => %{"username" => "root", "port" => 22}
    }
  end

  @impl true
  def unsupported_mode, do: "push"

  # Job work runs in Ssm.Mctl.TaskSupervisor; let it finish before the
  # sandbox owner goes away.
  @impl true
  def cleanup do
    for pid <- Task.Supervisor.children(Ssm.Mctl.TaskSupervisor) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end
  end
end
