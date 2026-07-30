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

  @doc "List entries newest-first, optionally filtered by `activity_type`."
  @spec list(keyword()) :: [ActivityLog.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    query =
      from l in ActivityLog,
        order_by: [desc: l.timestamp, desc: l.id],
        limit: ^limit,
        preload: [:user]

    query =
      case Keyword.get(opts, :activity_type) do
        type when type in @activity_types -> where(query, [l], l.activity_type == ^type)
        _ -> query
      end

    Repo.all(query)
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
end
