defmodule Ssm.Test.OwnKeyStub do
  @moduledoc """
  `Ssm.Ssh.OwnKey` stand-in for tests (`config :ssm, :own_key`): no key file
  needed. `Application.put_env(:ssm, :test_own_public_key, :unavailable)`
  simulates a missing `SSH_KEY`. `:test_own_key_hook` (a zero-arity fun)
  runs first – e.g. to delete the host while its create job runs.
  """

  @public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkbqSNcQO24DC7SNzK6+DVAaWrUSJW5fVaz+0JN8CnY"

  def default, do: @public_key

  def public_key do
    with f when is_function(f, 0) <- Application.get_env(:ssm, :test_own_key_hook), do: f.()

    case Application.get_env(:ssm, :test_own_public_key, @public_key) do
      :unavailable -> {:error, :ssm_key_unavailable}
      key -> {:ok, key}
    end
  end
end
