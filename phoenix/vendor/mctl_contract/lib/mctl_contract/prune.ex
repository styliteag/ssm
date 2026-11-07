defmodule MctlContract.Prune do
  @moduledoc false
  # Deletes the rows of `query` in batches of `batch_size` ids: short
  # statements and locks on large tables. Portable: the ids are read
  # first (MariaDB has no LIMIT in IN subqueries).
  import Ecto.Query

  @default_batch 1000

  def default_batch, do: @default_batch

  @spec delete_in_batches(module(), module(), Ecto.Queryable.t(), pos_integer()) ::
          non_neg_integer()
  def delete_in_batches(repo, schema, query, batch_size, deleted \\ 0) do
    ids = repo.all(from r in query, select: r.id, order_by: r.id, limit: ^batch_size)

    case ids do
      [] ->
        deleted

      ids ->
        {n, _} = repo.delete_all(from r in schema, where: r.id in ^ids)
        delete_in_batches(repo, schema, query, batch_size, deleted + n)
    end
  end
end
