defmodule Ssm.Diffs.DriftType do
  @moduledoc "Ecto type: a list of drift entries, stored as JSON text."
  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_other), do: :error

  @impl true
  def dump(list) when is_list(list), do: Jason.encode(list)
  def dump(_other), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end
end
