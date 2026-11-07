defmodule MctlContract.Page do
  @moduledoc """
  Parses list query parameters into the provider's page map
  `%{after: key | nil, limit: n, filters: map}`: `limit` (default 100,
  max 1000), `cursor` (`MctlContract.Cursor`) and the collection's
  filters. Empty filter values are ignored.
  """
  alias MctlContract.Cursor

  @default 100
  @max_string 1024
  @max 1000
  @job_states ~w(queued running succeeded failed)
  @maintenance_states ~w(planned active ended cancelled)

  @filters %{
    "hosts" => [{"changed_after", :datetime}, {"customer", :string}, {"group", :string}],
    "customers" => [],
    "groups" => [],
    "host_summaries" => [{"changed_after", :datetime}, {"host_id", :string}],
    "jobs" => [{"host_id", :string}, {"state", {:enum, @job_states}}],
    "maintenance" => [{"host_id", :string}, {"state", {:enum, @maintenance_states}}]
  }

  @doc "Filters of a collection: `[{name, type}]`."
  def filters(collection), do: Map.fetch!(@filters, collection)

  @doc "Job states."
  def job_states, do: @job_states

  @doc "Maintenance states."
  def maintenance_states, do: @maintenance_states

  @spec parse(map(), String.t(), [Cursor.type()] | :any) ::
          {:ok, MctlContract.Provider.page()} | {:error, String.t()}
  def parse(params, collection, types) do
    with {:ok, limit} <- limit(params["limit"]),
         {:ok, key} <- cursor(params["cursor"], collection, types),
         {:ok, filters} <- parse_filters(params, filters(collection)) do
      {:ok, %{after: key, limit: limit, filters: filters}}
    end
  end

  defp limit(nil), do: {:ok, @default}

  defp limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, min(n, @max)}
      _ -> {:error, "limit must be a positive integer"}
    end
  end

  defp limit(_), do: {:error, "limit must be a positive integer"}

  defp cursor(value, collection, types) when is_binary(value) or is_nil(value) do
    case Cursor.decode(value, collection, types) do
      {:ok, key} -> {:ok, key}
      {:error, :invalid_cursor} -> {:error, "invalid cursor"}
    end
  end

  defp cursor(_value, _collection, _types), do: {:error, "invalid cursor"}

  defp parse_filters(params, specs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {name, type}, {:ok, acc} ->
      case filter(params[name], name, type) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, v} -> {:cont, {:ok, Map.put(acc, name, v)}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp filter(v, _name, _type) when v in [nil, ""], do: :skip
  defp filter(v, name, _type) when not is_binary(v), do: {:error, "#{name} must be a string"}
  # same limits as cursor strings: bounded, no NUL (PostgreSQL text)
  defp filter(v, name, :string) do
    if byte_size(v) <= @max_string and not String.contains?(v, <<0>>),
      do: {:ok, v},
      else: {:error, "#{name} must be at most #{@max_string} bytes without NUL"}
  end

  defp filter(v, name, :datetime) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      _ -> {:error, "#{name} must be an ISO 8601 timestamp with offset"}
    end
  end

  defp filter(v, name, {:enum, values}) do
    if v in values,
      do: {:ok, v},
      else: {:error, "#{name} must be one of #{Enum.join(values, ", ")}"}
  end
end
