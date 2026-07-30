defmodule SsmWeb.TableSort do
  @moduledoc """
  Shared column sorting for the list LiveViews: `toggle/2` cycles a clicked
  header (new column → asc, same column → flips direction), `sort/3` applies
  the current sort through a per-page map of `key => sort_by` functions.
  A nil sort or unknown key leaves the rows in their natural order.
  """

  @type sort :: {String.t(), :asc | :desc} | nil

  @spec toggle(sort(), String.t()) :: sort()
  def toggle({key, :asc}, key), do: {key, :desc}
  def toggle(_current, key), do: {key, :asc}

  @spec sort([row], sort(), %{String.t() => (row -> term())}) :: [row] when row: term()
  def sort(rows, nil, _sorters), do: rows

  def sort(rows, {key, direction}, sorters) do
    case Map.fetch(sorters, key) do
      {:ok, fun} -> Enum.sort_by(rows, fun, direction)
      :error -> rows
    end
  end

  @doc "Case-insensitive string sort key; nil-safe (nils sort last as ~ >> letters)."
  @spec string(String.t() | nil) :: String.t()
  def string(nil), do: "~~~"
  def string(value), do: String.downcase(value)
end
