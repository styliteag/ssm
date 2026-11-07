defmodule MctlContract.Cursor do
  @moduledoc """
  Opaque keyset cursor, wire-identical to omon's API v2 keyset cursor:
  `base64url("v1:" <> JSON [collection | key])` without padding.

  The key is the sort key of the last item of a page, the last element
  unique. Decoding checks version, collection, arity and the type of every
  element. Types: `:string`, `:integer`, `:datetime` (ISO 8601 string,
  decoded to `DateTime`) and `:any` (string or integer, passed through).
  `types` may also be `:any` for a key of any arity.
  """

  @max_cursor 2048
  @max_string 1024
  @int8 9_223_372_036_854_775_808

  @type type :: :string | :integer | :datetime | :any

  @spec encode(String.t(), list()) :: String.t()
  def encode(collection, key) when is_binary(collection) and is_list(key) do
    json = Jason.encode!([collection | Enum.map(key, &dump/1)])
    Base.url_encode64("v1:" <> json, padding: false)
  end

  @spec decode(String.t() | nil, String.t(), [type()] | :any) ::
          {:ok, list() | nil} | {:error, :invalid_cursor}
  def decode(cursor, _collection, _types) when cursor in [nil, ""], do: {:ok, nil}

  def decode(cursor, collection, types)
      when is_binary(cursor) and byte_size(cursor) <= @max_cursor do
    with {:ok, "v1:" <> json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [^collection | values]} when values != [] <- Jason.decode(json),
         {:ok, key} <- cast_all(values, expand(types, values)) do
      {:ok, key}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_cursor, _collection, _types), do: {:error, :invalid_cursor}

  defp expand(:any, values), do: List.duplicate(:any, length(values))
  defp expand(types, values) when length(types) == length(values), do: types
  defp expand(_types, _values), do: :mismatch

  defp cast_all(_values, :mismatch), do: :error

  defp cast_all(values, types) do
    values
    |> Enum.zip(types)
    |> Enum.reduce_while({:ok, []}, fn {v, t}, {:ok, acc} ->
      case cast(v, t) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # PostgreSQL text holds no NUL byte
  defp cast(v, :string) when is_binary(v) and byte_size(v) <= @max_string,
    do: if(String.contains?(v, <<0>>), do: :error, else: {:ok, v})

  # bigint range: a larger value would fail in the database
  defp cast(v, :integer) when is_integer(v) and v >= -@int8 and v < @int8, do: {:ok, v}

  defp cast(v, :datetime) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, %DateTime{year: y} = dt, 0} when y in 1..9999 -> {:ok, dt}
      _ -> :error
    end
  end

  defp cast(v, :any) when is_binary(v), do: cast(v, :string)
  defp cast(v, :any) when is_integer(v), do: cast(v, :integer)
  defp cast(_v, _type), do: :error

  defp dump(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp dump(v), do: v
end
