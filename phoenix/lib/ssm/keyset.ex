defmodule Ssm.Keyset do
  @moduledoc """
  Keyset paging on one unique, sortable column: fetch `limit + 1` rows
  after the key; the extra row only signals that more exist.
  """

  import Ecto.Query

  alias Ssm.Repo

  @spec page(Ecto.Queryable.t(), atom(), term() | nil, pos_integer()) ::
          {[struct()], term() | nil}
  def page(queryable, field, after_key, limit) when is_integer(limit) and limit > 0 do
    queryable
    |> after_key(field, after_key)
    |> order_by([r], asc: field(r, ^field))
    |> limit(^(limit + 1))
    |> Repo.all()
    |> split(field, limit)
  end

  defp after_key(query, _field, nil), do: query
  defp after_key(query, field, key), do: where(query, [r], field(r, ^field) > ^key)

  @doc "Cut a `limit + 1` result into the page and the next key (or nil)."
  @spec split([struct()], atom(), pos_integer()) :: {[struct()], term() | nil}
  def split(rows, field, limit) do
    case Enum.split(rows, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, page |> List.last() |> Map.fetch!(field)}
    end
  end
end
