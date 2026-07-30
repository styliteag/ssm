defmodule SsmWeb.Api.ActivityLogController do
  @moduledoc """
  `/api/v2/activity-log` — python `api/v2/activity_log.py`: newest-first,
  `page`/`page_size` (1..200) pagination with a total in `meta`, optional
  `activity_type` filter. `meta` (the JSON details column) ships raw.
  """

  use SsmWeb, :controller

  import Ecto.Query

  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @query_spec [
    page: [type: :integer, default: 1, min: 1],
    page_size: [type: :integer, default: 50, min: 1, max: 200],
    activity_type: [type: :string, max_len: 32]
  ]

  def index(conn, params) do
    case Params.validate(params, @query_spec) do
      {:ok, query_params} -> list(conn, query_params)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  defp list(conn, %{page: page, page_size: page_size} = query_params) do
    base = filter_type(ActivityLog, query_params[:activity_type])
    total = Repo.aggregate(base, :count)

    rows =
      Repo.all(
        from l in base,
          order_by: [desc: l.timestamp, desc: l.id],
          offset: ^((page - 1) * page_size),
          limit: ^page_size
      )

    Envelope.ok(
      conn,
      Enum.map(rows, &entry_json/1),
      meta: Envelope.meta(total: total, page: page, page_size: page_size)
    )
  end

  defp filter_type(query, nil), do: query
  defp filter_type(query, type), do: where(query, [l], l.activity_type == ^type)

  defp entry_json(%ActivityLog{} = entry) do
    %{
      id: entry.id,
      activity_type: entry.activity_type,
      action: entry.action,
      target: entry.target,
      user_id: entry.user_id,
      actor_username: entry.actor_username,
      timestamp: entry.timestamp,
      meta: entry.meta
    }
  end
end
