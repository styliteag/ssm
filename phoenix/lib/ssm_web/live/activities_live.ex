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

  alias SsmWeb.ActivityText
  alias SsmWeb.Layouts

  @page_size 50
  # "Load more" stops here: every click re-reads the whole list
  @max_entries 1000

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Activity")}
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
     |> assign(:actor_name, blank_to_nil(params["actor"]))
     |> assign(:from, parse_date(params["from"]))
     |> assign(:to, parse_date(params["to"]))
     |> assign(:actors, Activity.actors(Ssm.Scope.of(socket.assigns.current_user)))
     |> assign(:limit, @page_size)
     |> reload_entries()}
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  # ?from= / ?to= are calendar days (YYYY-MM-DD) in the viewer's zone; anything else is no bound
  @doc false
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def parse_date(_value), do: nil

  # unix seconds (UTC) of the first / last second of the local day
  defp day_start(nil, _zone), do: nil
  defp day_start(%Date{} = date, zone), do: date |> SsmWeb.TimeZone.day_range(zone) |> elem(0)

  defp day_end(nil, _zone), do: nil
  defp day_end(%Date{} = date, zone), do: date |> SsmWeb.TimeZone.day_range(zone) |> elem(1)

  defp reload_entries(socket) do
    user = socket.assigns.current_user

    # scoped users: entries of hosts in scope and their own (ADR-0012)
    entries =
      Activity.list(Ssm.Scope.of(user),
        actor: user.actor,
        limit: socket.assigns.limit + 1,
        activity_type: socket.assigns.filter_type,
        search: socket.assigns.search,
        actor_name: socket.assigns.actor_name,
        from: day_start(socket.assigns.from, socket.assigns.time_zone),
        to: day_end(socket.assigns.to, socket.assigns.time_zone)
      )

    {visible, more} = Enum.split(entries, socket.assigns.limit)

    socket
    |> assign(:has_more, more != [] and socket.assigns.limit < @max_entries)
    |> assign(:capped, more != [] and socket.assigns.limit >= @max_entries)
    |> assign(:entry_count, length(visible))
    |> stream(:activities, visible, reset: true)
  end

  ## Events

  @impl true
  def handle_event("filter", params, socket) do
    query =
      [
        {"type", params["type"]},
        {"q", params["q"]},
        {"actor", params["actor"]},
        {"from", params["from"]},
        {"to", params["to"]}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    to = if query == %{}, do: ~p"/activities", else: ~p"/activities?#{query}"

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> update(:limit, &min(&1 + @page_size, @max_entries))
     |> reload_entries()}
  end

  ## Helpers

  defp display(nil), do: "—"
  defp display(value) when is_binary(value), do: value
  defp display(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp display(value), do: Jason.encode!(value)

  ## Render

  # where an entry's target lives: the host's diff, else a search on the page
  # of its kind (names are not unique ids, a search finds renamed ones too)
  defp target_path(%{host_id: id}) when is_integer(id), do: host_path(id)
  defp target_path(%{target: t}) when t in [nil, ""], do: nil
  defp target_path(%{activity_type: "user", target: t}), do: ~p"/users?q=#{t}"
  defp target_path(%{activity_type: "key", target: t}), do: ~p"/keys?q=#{t}"
  defp target_path(%{activity_type: "auth", target: t}), do: ~p"/access?q=#{t}"
  defp target_path(_entry), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:activities}
    >
      <.header>
        Activity
        <:subtitle>Audit trail, newest first</:subtitle>
      </.header>

      <form id="activities-filter" phx-change="filter" class="flex flex-wrap items-end gap-3">
        <div class="min-w-48 flex-1">
          <.input
            type="search"
            name="q"
            value={@search}
            label="Search"
            placeholder="Action, target, or actor…"
            phx-debounce="300"
          />
        </div>
        <div class="min-w-40">
          <.input
            type="select"
            name="type"
            value={@filter_type}
            label="Filter by type"
            prompt="All types"
            options={[{"Host", "host"}, {"User", "user"}, {"Key", "key"}, {"Access", "auth"}]}
          />
        </div>
        <div class="min-w-48">
          <.input
            id="activity-actor"
            type="select"
            name="actor"
            value={@actor_name}
            label="Actor"
            prompt="All actors"
            searchable
            options={@actors}
          />
        </div>
        <div>
          <.input type="date" name="from" value={@from} label={"From (#{@time_zone})"} />
        </div>
        <div>
          <.input type="date" name="to" value={@to} label={"To (#{@time_zone})"} />
        </div>
      </form>

      <p :if={@entry_count == 0} class="text-sm opacity-60">
        {if @search || @filter_type || @actor_name || @from || @to,
          do: "No matching activity.",
          else: "No activity recorded."}
      </p>

      <ul :if={@entry_count > 0} id="activities" phx-update="stream" class="space-y-1">
        <li
          :for={{id, entry} <- @streams.activities}
          id={id}
          class="rounded-box bg-base-200 px-3 py-2 text-sm"
        >
          <div class="flex items-center gap-3">
            <span class={["badge badge-sm flex-none", ActivityText.type_class(entry.activity_type)]}>
              {entry.activity_type}
            </span>
            <span class="font-medium" title={entry.action}>{ActivityText.action(entry.action)}</span>
            <.link
              :if={target_path(entry)}
              navigate={target_path(entry)}
              class="link link-hover truncate opacity-75"
              title="Open"
              aria-label="Open"
            >
              {entry.target}
            </.link>
            <span :if={!target_path(entry)} class="truncate opacity-75">{entry.target}</span>
            <span class="ml-auto flex-none text-xs opacity-60">
              <.local_time at={entry.timestamp} zone={@time_zone} fmt="datetime-sec" />
              · {entry.actor_username}
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
      <p :if={@capped} id="activities-capped" class="text-center text-xs opacity-70">
        Showing the newest {@limit} entries — narrow the filter or search to see older ones.
      </p>
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
    <details class="mt-1.5" data-details="changes" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary class="cursor-pointer text-xs opacity-60">Details ({length(@changes)})</summary>
      <div class="mt-1 flex flex-wrap gap-1.5">
        <span :for={{field, old, new} <- @changes} class="badge badge-ghost badge-sm font-mono">
          <span class="opacity-70">{field}:</span>
          <s class="text-error">{display(old)}</s>
          <span aria-hidden="true">→</span>
          <span class="text-success">{display(new)}</span>
        </span>
      </div>
    </details>
    """
  end

  defp details_body(%{shape: {:summary, pairs}} = assigns) do
    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <details class="mt-1.5" data-details="summary" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary class="cursor-pointer text-xs opacity-60">Details ({length(@pairs)})</summary>
      <div class="mt-1 flex flex-wrap gap-1.5">
        <span :for={{key, value} <- @pairs} class="badge badge-ghost badge-sm font-mono">
          {key}: {display(value)}
        </span>
      </div>
    </details>
    """
  end

  defp details_body(%{shape: {:raw, map}} = assigns) do
    assigns = assign(assigns, :json, Jason.encode!(map, pretty: true))

    ~H"""
    <details class="mt-1.5" data-details="raw" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary class="cursor-pointer text-xs opacity-60">Details</summary>
      <pre class="mt-1 overflow-x-auto rounded bg-base-300 p-2 font-mono text-xs">{@json}</pre>
    </details>
    """
  end
end
