defmodule SsmWeb.ActivitiesLive do
  @moduledoc """
  Activity log page: newest-first audit trail with a type filter
  (`?type=key|host|user|auth`), free-text search (`?q=`) across
  action/target/actor, and structured metadata rendering — the React
  ActivitiesPage core.

  Metadata renders as chips for field-change maps (`old → new`) and flat
  summary maps (sync counters, host address/port, key type); anything else
  falls back to pretty JSON inside a native `<details>` element.

  Deliberate deviation from the React page: there is no IP badge — the
  `activity_log` schema has no IP column, so the React `metadata.ip` badge
  has nothing to read here.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity

  alias SsmWeb.Layouts

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Activities")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter_type =
      case params["type"] do
        type when type in ~w(key host user auth) -> type
        _ -> nil
      end

    search =
      case params["q"] do
        q when is_binary(q) -> if String.trim(q) == "", do: nil, else: q
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_type, filter_type)
     |> assign(:search, search)
     |> assign(:limit, @page_size)
     |> reload_entries()}
  end

  defp reload_entries(socket) do
    entries =
      Activity.list(
        limit: socket.assigns.limit + 1,
        activity_type: socket.assigns.filter_type,
        search: socket.assigns.search
      )

    {visible, more} = Enum.split(entries, socket.assigns.limit)

    socket
    |> assign(:has_more, more != [])
    |> assign(:entry_count, length(visible))
    |> stream(:activities, visible, reset: true)
  end

  ## Events

  @impl true
  def handle_event("filter", params, socket) do
    query =
      [{"type", params["type"]}, {"q", params["q"]}]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    to = if query == %{}, do: ~p"/activities", else: ~p"/activities?#{query}"

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> update(:limit, &(&1 + @page_size))
     |> reload_entries()}
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

  defp display(nil), do: "null"
  defp display(value) when is_binary(value), do: value
  defp display(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp display(value), do: Jason.encode!(value)

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:activities}>
      <.header>
        Activities
        <:subtitle>Audit trail, newest first</:subtitle>
      </.header>

      <form id="activities-filter" phx-change="filter" class="flex max-w-xl gap-3">
        <div class="flex-1">
          <.input
            type="search"
            name="q"
            value={@search}
            label="Search"
            placeholder="Action, target, or actor…"
            phx-debounce="300"
          />
        </div>
        <div class="flex-1">
          <.input
            type="select"
            name="type"
            value={@filter_type}
            label="Filter by type"
            prompt="All types"
            options={[{"Host", "host"}, {"User", "user"}, {"Key", "key"}, {"Authorization", "auth"}]}
          />
        </div>
      </form>

      <p :if={@entry_count == 0} class="text-sm opacity-60">
        {if @search || @filter_type, do: "No matching activity.", else: "No activity recorded."}
      </p>

      <ul :if={@entry_count > 0} id="activities" phx-update="stream" class="space-y-1">
        <li
          :for={{id, entry} <- @streams.activities}
          id={id}
          class="rounded-box bg-base-200 px-3 py-2 text-sm"
        >
          <div class="flex items-center gap-3">
            <span class={["badge badge-sm flex-none", type_badge_class(entry.activity_type)]}>
              {entry.activity_type}
            </span>
            <span class="font-medium">{entry.action}</span>
            <span class="truncate opacity-75">{entry.target}</span>
            <span class="ml-auto flex-none text-xs opacity-60">
              {format_timestamp(entry.timestamp)} · {entry.actor_username}
            </span>
          </div>

          <.entry_details entry={entry} />
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

  attr :entry, Ssm.Activity.ActivityLog, required: true

  defp entry_details(assigns) do
    shape = assigns.entry |> Activity.details() |> Activity.classify_details()
    assigns = assign(assigns, :shape, shape)

    ~H"""
    <.details_body shape={@shape} />
    """
  end

  attr :shape, :any, required: true

  defp details_body(%{shape: :none} = assigns), do: ~H""

  defp details_body(%{shape: {:field_changes, changes}} = assigns) do
    assigns = assign(assigns, :changes, changes)

    ~H"""
    <div class="mt-1.5 flex flex-wrap gap-1.5" data-details="changes">
      <span :for={{field, old, new} <- @changes} class="badge badge-ghost badge-sm font-mono">
        <span class="opacity-70">{field}:</span>
        <s class="text-error">{display(old)}</s>
        <span aria-hidden="true">→</span>
        <span class="text-success">{display(new)}</span>
      </span>
    </div>
    """
  end

  defp details_body(%{shape: {:summary, pairs}} = assigns) do
    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <div class="mt-1.5 flex flex-wrap gap-1.5" data-details="summary">
      <span :for={{key, value} <- @pairs} class="badge badge-ghost badge-sm font-mono">
        {key}: {display(value)}
      </span>
    </div>
    """
  end

  defp details_body(%{shape: {:raw, map}} = assigns) do
    assigns = assign(assigns, :json, Jason.encode!(map, pretty: true))

    ~H"""
    <details class="mt-1.5" data-details="raw">
      <summary class="cursor-pointer text-xs opacity-60">Details</summary>
      <pre class="mt-1 overflow-x-auto rounded bg-base-300 p-2 font-mono text-xs">{@json}</pre>
    </details>
    """
  end
end
