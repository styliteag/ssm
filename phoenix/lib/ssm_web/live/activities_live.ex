defmodule SsmWeb.ActivitiesLive do
  @moduledoc """
  Activity log page: newest-first audit trail with a type filter
  (`?type=key|host|user|auth`) and expandable detail rows — the React
  ActivitiesPage core.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Activity.ActivityLog
  alias SsmWeb.Layouts

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Activities", expanded_id: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter_type =
      case params["type"] do
        type when type in ~w(key host user auth) -> type
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_type, filter_type)
     |> assign(:limit, @page_size)
     |> reload_entries()}
  end

  defp reload_entries(socket) do
    opts =
      [limit: socket.assigns.limit + 1] ++
        case socket.assigns.filter_type do
          nil -> []
          type -> [activity_type: type]
        end

    entries = Activity.list(opts)
    {visible, more} = Enum.split(entries, socket.assigns.limit)

    socket
    |> assign(:has_more, more != [])
    |> assign(:entry_count, length(visible))
    |> stream(:activities, visible, reset: true)
  end

  ## Events

  @impl true
  def handle_event("filter", %{"type" => value}, socket) do
    to =
      case value do
        "" -> ~p"/activities"
        type -> ~p"/activities?type=#{type}"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> update(:limit, &(&1 + @page_size))
     |> reload_entries()}
  end

  def handle_event("toggle_details", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded_id = if socket.assigns.expanded_id == id, do: nil, else: id

    socket = assign(socket, :expanded_id, expanded_id)

    # Re-stream the toggled rows so the expansion state change renders.
    socket =
      [socket.assigns.expanded_id, expanded_id, id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(socket, fn entry_id, acc ->
        case Ssm.Repo.get(ActivityLog, entry_id) do
          nil -> acc
          entry -> stream_insert(acc, :activities, Ssm.Repo.preload(entry, :user))
        end
      end)

    {:noreply, socket}
  end

  ## Helpers

  defp format_timestamp(nil), do: ""

  defp format_timestamp(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp type_badge_class("host"), do: "badge-info"
  defp type_badge_class("user"), do: "badge-success"
  defp type_badge_class("key"), do: "badge-warning"
  defp type_badge_class("auth"), do: "badge-secondary"
  defp type_badge_class(_), do: "badge-ghost"

  defp details_json(entry) do
    case Activity.details(entry) do
      nil -> nil
      map -> Jason.encode!(map, pretty: true)
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:activities}>
      <.header>
        Activities
        <:subtitle>Audit trail, newest first</:subtitle>
      </.header>

      <form id="activities-filter" phx-change="filter" class="max-w-xs">
        <.input
          type="select"
          name="type"
          value={@filter_type}
          label="Filter by type"
          prompt="All types"
          options={[{"Host", "host"}, {"User", "user"}, {"Key", "key"}, {"Authorization", "auth"}]}
        />
      </form>

      <p :if={@entry_count == 0} class="text-sm opacity-60">No activity recorded.</p>

      <ul :if={@entry_count > 0} id="activities" phx-update="stream" class="space-y-1">
        <li
          :for={{id, entry} <- @streams.activities}
          id={id}
          class="rounded-box bg-base-200 px-3 py-2 text-sm"
        >
          <button
            class="flex w-full items-center gap-3 text-left"
            phx-click="toggle_details"
            phx-value-id={entry.id}
          >
            <span class={["badge badge-sm flex-none", type_badge_class(entry.activity_type)]}>
              {entry.activity_type}
            </span>
            <span class="font-medium">{entry.action}</span>
            <span class="truncate opacity-75">{entry.target}</span>
            <span class="ml-auto flex-none text-xs opacity-60">
              {format_timestamp(entry.timestamp)} · {entry.actor_username}
            </span>
          </button>

          <pre
            :if={@expanded_id == entry.id && details_json(entry)}
            class="mt-2 overflow-x-auto rounded bg-base-300 p-2 font-mono text-xs"
          >{details_json(entry)}</pre>
          <p :if={@expanded_id == entry.id && !details_json(entry)} class="mt-2 text-xs opacity-60">
            No details recorded.
          </p>
        </li>
      </ul>

      <div :if={@has_more} class="flex justify-center">
        <button id="load-more" class="btn btn-ghost btn-sm" phx-click="load_more">
          Load more
        </button>
      </div>
    </Layouts.app>
    """
  end
end
