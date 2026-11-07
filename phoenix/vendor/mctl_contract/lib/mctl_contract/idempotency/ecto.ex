defmodule MctlContract.Idempotency.Ecto do
  @moduledoc """
  Default `MctlContract.IdempotencyStore`: table `mctl_idempotency` in the
  tool's repo. Keys live 24 hours; a key whose first request never
  finished (no status after 5 minutes) counts as abandoned. Portable: the
  claim is a plain insert guarded by the unique index, no `RETURNING` or
  conflict target.
  """
  @behaviour MctlContract.IdempotencyStore

  import Ecto.Query

  alias MctlContract.Idempotency.Record

  @ttl_seconds 24 * 3600
  @abandon_seconds 300

  @impl true
  def claim(token_id, key, request_hash), do: claim(token_id, key, request_hash, 1)

  defp claim(token_id, key, request_hash, retries) do
    expire(token_id, key)

    cs =
      %Record{}
      |> Ecto.Changeset.change(
        token_id: token_id,
        key: key,
        request_hash: request_hash,
        inserted_at: DateTime.utc_now(:second)
      )
      |> Ecto.Changeset.unique_constraint([:token_id, :key])

    case repo().insert(cs) do
      {:ok, record} ->
        {:new, record.id}

      {:error, _cs} ->
        Record
        |> repo().get_by(token_id: token_id, key: key)
        |> on_conflict(token_id, key, request_hash, retries)
    end
  end

  @doc false
  # The insert hit an existing record. A record deleted in between (its
  # first request failed) is claimed again, once; losing that race too
  # answers :in_progress (409, the client retries later).
  def on_conflict(record, token_id, key, request_hash, retries) do
    case record do
      %{request_hash: ^request_hash, status: nil} -> :in_progress
      %{request_hash: ^request_hash} = r -> {:replay, %{status: r.status, response: r.response}}
      %{} -> :mismatch
      nil when retries > 0 -> claim(token_id, key, request_hash, retries - 1)
      nil -> :in_progress
    end
  end

  defp expire(token_id, key) do
    now = DateTime.utc_now(:second)
    cutoff = DateTime.add(now, -@ttl_seconds)
    abandoned = DateTime.add(now, -@abandon_seconds)

    repo().delete_all(
      from r in Record,
        where:
          r.token_id == ^token_id and r.key == ^key and
            (r.inserted_at < ^cutoff or (is_nil(r.status) and r.inserted_at < ^abandoned))
    )
  end

  @impl true
  def complete(id, status, body) do
    repo().update_all(from(r in Record, where: r.id == ^id),
      set: [status: status, response: body]
    )

    :ok
  end

  @impl true
  def release(id) do
    repo().delete_all(from r in Record, where: r.id == ^id)
    :ok
  end

  @doc """
  Deletes keys older than 24 hours in batches (option `batch_size`,
  default 1000); returns the number deleted.
  """
  def prune(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@ttl_seconds)
    batch = Keyword.get(opts, :batch_size, MctlContract.Prune.default_batch())

    MctlContract.Prune.delete_in_batches(
      repo(),
      Record,
      from(r in Record, where: r.inserted_at < ^cutoff),
      batch
    )
  end

  defp repo, do: MctlContract.Repo.get()
end
