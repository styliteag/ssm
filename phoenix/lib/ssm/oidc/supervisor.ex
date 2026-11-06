defmodule Ssm.OIDC.Supervisor do
  @moduledoc """
  Isolates the oidcc provider worker. If the identity provider misbehaves
  so badly that the worker keeps crashing, this supervisor gives up (and
  the application keeps running with a dead SSO button and working local
  login) instead of taking the whole app down with its restart intensity.
  """

  use Supervisor

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [Ssm.OIDC.Config.provider_child_spec(Ssm.OIDC.Config.get())]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end
end
