defmodule Ssm.Activity do
  @moduledoc """
  Append-only audit trail — port of activity_logger.py plus the
  `/api/v2/activity-log` read side. `log/1` never raises on a bad write; an
  audit-log failure must not abort the user action that triggered it.
  """

  import Ecto.Query
  require Logger

  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  @activity_types ~w(key host user auth)

  @doc """
  Append one entry. `details` is JSON-encoded into the `metadata` column.
  Returns `{:ok, entry}` or `{:error, reason}`; callers typically ignore it.
  """
  @spec log(map()) :: {:ok, ActivityLog.t()} | {:error, term()}
  def log(attrs) do
    attrs = normalize(attrs)

    %ActivityLog{}
    |> ActivityLog.changeset(attrs)
    |> Repo.insert()
  rescue
    error ->
      Logger.warning("activity_log write failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> encode_details()
  end

  defp encode_details(%{"details" => details} = attrs) when is_map(details) do
    attrs |> Map.delete("details") |> Map.put("meta", Jason.encode!(details))
  end

  defp encode_details(attrs), do: Map.delete(attrs, "details")

  @doc """
  List entries newest-first. Options:

    * `:limit` — max rows (default 200)
    * `:activity_type` — one of `key`, `host`, `user`, `auth`
    * `:search` — case-insensitive substring match against action, target,
      or actor_username (LIKE wildcards in the term are escaped)
  """
  @spec list(keyword()) :: [ActivityLog.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    query =
      from l in ActivityLog,
        order_by: [desc: l.timestamp, desc: l.id],
        limit: ^limit,
        preload: [:user]

    query
    |> filter_type(Keyword.get(opts, :activity_type))
    |> filter_search(Keyword.get(opts, :search))
    |> Repo.all()
  end

  defp filter_type(query, type) when type in @activity_types,
    do: where(query, [l], l.activity_type == ^type)

  defp filter_type(query, _type), do: query

  defp filter_search(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> escape_like(String.downcase(term)) <> "%"

    where(
      query,
      [l],
      fragment("lower(?) LIKE ? ESCAPE '\\'", l.action, ^pattern) or
        fragment("lower(?) LIKE ? ESCAPE '\\'", l.target, ^pattern) or
        fragment("lower(?) LIKE ? ESCAPE '\\'", l.actor_username, ^pattern)
    )
  end

  defp filter_search(query, _term), do: query

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc "Decode an entry's `meta` JSON back into a map (or nil)."
  @spec details(ActivityLog.t()) :: map() | nil
  def details(%ActivityLog{meta: nil}), do: nil

  def details(%ActivityLog{meta: meta}) do
    case Jason.decode(meta) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  @doc """
  Classify decoded details (string-keyed, as returned by `details/1`) for
  structured rendering:

    * `{:field_changes, [{field, old, new}]}` — every value is a map with
      `"old"` and `"new"` keys (update-style change sets, sorted by field)
    * `{:summary, [{key, value}]}` — flat map of scalars, sorted by key;
      covers everything written today: host `address`/`port`, key
      `key_type`, and the sync counters `logins`/`keys`
    * `{:raw, map}` — anything nested or mixed; render as pretty JSON
    * `:none` — nil or empty
  """
  @spec classify_details(map() | nil) ::
          :none
          | {:field_changes, [{String.t(), term(), term()}]}
          | {:summary, [{String.t(), term()}]}
          | {:raw, map()}
  def classify_details(nil), do: :none
  def classify_details(map) when map == %{}, do: :none

  def classify_details(map) when is_map(map) do
    cond do
      Enum.all?(map, &field_change?/1) ->
        {:field_changes,
         map
         |> Enum.sort()
         |> Enum.map(fn {field, %{"old" => old, "new" => new}} -> {field, old, new} end)}

      Enum.all?(map, fn {_key, value} -> scalar?(value) end) ->
        {:summary, Enum.sort(map)}

      true ->
        {:raw, map}
    end
  end

  defp field_change?({_field, %{"old" => _, "new" => _}}), do: true
  defp field_change?(_entry), do: false

  defp scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp scalar?(_value), do: false
end
