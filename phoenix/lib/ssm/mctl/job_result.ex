defmodule Ssm.Mctl.JobResult do
  @moduledoc """
  Interim results of a running `mctl_jobs` job. The library's job store
  writes a result only when the job succeeds; ssm's `create_host` job hands
  out `ssm_public_key` while it is still `running` (onboarding v2 §4), so
  mctl can authorize the key before the job's login succeeds. `succeed/2`
  later replaces the whole result, so the final result repeats the key.
  """

  alias MctlContract.Jobs.Job
  alias Ssm.Repo

  @doc "Replace the result (a JSON map) of job `id` (string id)."
  @spec put(String.t(), map()) :: :ok | {:error, :not_found}
  def put(id, result) when is_binary(id) and is_map(result) do
    case Repo.get(Job, String.to_integer(id)) do
      nil ->
        {:error, :not_found}

      job ->
        job |> Ecto.Changeset.change(result: Jason.encode!(result)) |> Repo.update!()
        :ok
    end
  end
end
