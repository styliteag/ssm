defmodule MctlContract.Repo do
  @moduledoc """
  The tool's Ecto repo used by the library's Ecto stores:

      config :mctl_contract, repo: MyApp.Repo
  """

  @spec get() :: module()
  def get do
    Application.get_env(:mctl_contract, :repo) ||
      raise ArgumentError, "configure the repo: config :mctl_contract, repo: MyApp.Repo"
  end
end
