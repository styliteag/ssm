defmodule SsmWeb.DiffLive do
  @moduledoc """
  Diff viewer: per-host comparison of the DB's expected authorized_keys
  against what is on the host, with single-host sync and sync-all — the
  React DiffPage. Disabled hosts are marked and never touched
  (non-negotiable rule #4); readonly logins surface as badges and sync
  refusals, never partial writes (`Ssm.Diffs.sync_host/2` semantics).

  Unauthorized keys found on a host can be legitimized in place (database
  writes only, the host itself is untouched until the next sync): a key
  belonging to a known user gets an "Allow" button that grants that user the
  login; an unknown key can be assigned to a user, which also grants the
  login if missing.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Authorizations
  alias Ssm.Diffs
  alias Ssm.Diffs.HostDiff
  alias Ssm.Diffs.StatusCache
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias Ssm.Users
  alias Ssm.Users.KeyParser
  alias Ssm.Users.UserKey
  alias SsmWeb.Layouts

  # Cached statuses older than this are re-checked on mount.
  @status_ttl_ms 5 * 60 * 1000

  @impl true
  def mount(_params, _session, socket) do
    hosts = Hosts.list_hosts()
    cached = StatusCache.all()

    # Last known result shows immediately (the React app kept these in
    # browser state); only missing or stale hosts get re-checked.
    statuses =
      Map.new(hosts, fn host ->
        cond do
          host.disabled -> {host.id, :disabled}
          match?({_status, _at}, cached[host.id]) -> {host.id, elem(cached[host.id], 0)}
          true -> {host.id, :loading}
        end
      end)

    socket =
      socket
      |> assign(page_title: "Diff Viewer")
      |> assign(hosts: hosts, statuses: statuses, syncing: false)
      |> assign(detail: nil, detail_error: nil, detail_loading: false)
      |> assign(key_owners: %{}, unknown_key: nil)
      |> assign(diff_search: "", diff_sort: nil)

    socket =
      if connected?(socket) do
        to_check = Enum.reject(hosts, fn host -> host.disabled or fresh?(cached[host.id]) end)
        start_statuses_async(socket, to_check)
      else
        socket
      end

    {:ok, socket}
  end

  defp fresh?({_status, cached_at}),
    do: System.monotonic_time(:millisecond) - cached_at < @status_ttl_ms

  defp fresh?(nil), do: false

  @impl true
  def handle_params(params, _uri, socket) do
    selected =
      with raw when is_binary(raw) <- params["host_id"],
           {id, ""} <- Integer.parse(raw) do
        Enum.find(socket.assigns.hosts, &(&1.id == id))
      else
        _ -> nil
      end

    view = if params["view"] == "cards", do: "cards", else: "list"

    socket =
      assign(socket, selected: selected, detail: nil, detail_error: nil, diff_view: view)

    socket =
      if (connected?(socket) and selected) && !selected.disabled do
        start_detail_async(socket, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Async work

  # Each host's result streams back the moment it is known (`{:host_status,
  # id, status}` messages) instead of one all-or-nothing batch — with dozens
  # of hosts and a 120s timeout on dead ones, a single batch kept every badge
  # on "checking…" for minutes.
  defp start_statuses_async(socket, hosts) do
    ids = Enum.map(hosts, & &1.id)
    parent = self()

    concurrency = check_concurrency()

    start_async(socket, :statuses, fn ->
      ids
      |> Task.async_stream(
        fn id -> send(parent, {:host_status, id, status_for(id)}) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()
    end)
  end

  # SSH_CONCURRENCY (default 32) — how many hosts are checked in parallel.
  defp check_concurrency do
    Application.get_env(:ssm, :ssh, [])
    |> Keyword.get(:check_concurrency, 32)
  end

  defp start_detail_async(socket, %Host{id: id}) do
    socket
    |> assign(:detail_loading, true)
    |> start_async(:detail, fn -> Diffs.host_diff(id) end)
  end

  defp status_for(host_id) do
    case Diffs.host_diff(host_id) do
      {:ok, diff} -> summarize(diff)
      {:error, {:host_disabled, _}} -> :disabled
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp summarize(%HostDiff{logins: logins}) do
    read_error = Enum.find_value(logins, & &1.read_error)

    if read_error do
      {:error, read_error}
    else
      items = Enum.flat_map(logins, & &1.items)
      missing = Enum.count(items, &(&1.status == :missing_on_host))
      extra = Enum.count(items, &(&1.status == :extra_on_host))

      if missing + extra == 0, do: :synced, else: {:needs_sync, missing, extra}
    end
  end

  @impl true
  def handle_async(:statuses, {:ok, _done}, socket) do
    {:noreply, socket}
  end

  def handle_async(:statuses, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Status check crashed: #{inspect(reason)}")}
  end

  def handle_async(:detail, {:ok, result}, socket) do
    socket = assign(socket, :detail_loading, false)

    case result do
      {:ok, %HostDiff{} = diff} ->
        statuses = Map.put(socket.assigns.statuses, diff.host_id, summarize(diff))
        owners = Map.new(Users.list_keys(), &{&1.key_base64, &1.user})

        {:noreply,
         assign(socket, detail: diff, detail_error: nil, statuses: statuses, key_owners: owners)}

      {:error, reason} ->
        {:noreply, assign(socket, detail: nil, detail_error: format_reason(reason))}
    end
  end

  def handle_async(:detail, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(detail_loading: false, detail_error: "Diff crashed: #{inspect(reason)}")}
  end

  def handle_async(:sync, {:ok, {host, result}}, socket) do
    socket = assign(socket, :syncing, false)

    case result do
      {:ok, synced} ->
        keys = synced |> Enum.map(& &1.written_keys) |> Enum.sum()

        log_sync(socket, host, %{logins: length(synced), keys: keys})

        socket =
          socket
          |> put_flash(
            :info,
            "Synced #{host.name}: #{length(synced)} logins, #{keys} keys written."
          )
          |> refresh_after_sync(host)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Sync of #{host.name} failed: #{format_reason(reason)}")}
    end
  end

  def handle_async(:sync, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, "Sync crashed: #{inspect(reason)}")}
  end

  def handle_async(:sync_all, {:ok, results}, socket) do
    socket = assign(socket, :syncing, false)
    ok = Enum.count(results, fn {_host, result} -> match?({:ok, _}, result) end)
    failed = length(results) - ok

    for {host, {:ok, synced}} <- results do
      keys = synced |> Enum.map(& &1.written_keys) |> Enum.sum()
      log_sync(socket, host, %{logins: length(synced), keys: keys})
    end

    hosts = Enum.reject(socket.assigns.hosts, & &1.disabled)

    message =
      if failed == 0 do
        "Sync all done: #{ok} hosts synced."
      else
        "Sync all done: #{ok} synced, #{failed} failed."
      end

    kind = if failed == 0, do: :info, else: :error

    {:noreply,
     socket
     |> put_flash(kind, message)
     |> start_statuses_async(hosts)}
  end

  def handle_async(:sync_all, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, "Sync all crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:host_status, host_id, status}, socket) do
    StatusCache.put(host_id, status)
    {:noreply, update(socket, :statuses, &Map.put(&1, host_id, status))}
  end

  defp refresh_after_sync(socket, host) do
    if socket.assigns.selected && socket.assigns.selected.id == host.id do
      start_detail_async(socket, host)
    else
      start_statuses_async(socket, [host])
    end
  end

  ## Events

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{[view: socket.assigns.diff_view, host_id: id]}")}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{[view: socket.assigns.diff_view]}")}
  end

  def handle_event("refresh", _params, socket) do
    case socket.assigns.selected do
      %Host{disabled: false} = host -> {:noreply, start_detail_async(socket, host)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("diff-view", %{"view" => view}, socket) when view in ~w(cards list) do
    query =
      if socket.assigns.selected,
        do: [view: view, host_id: socket.assigns.selected.id],
        else: [view: view]

    {:noreply, push_patch(socket, to: ~p"/diff?#{query}")}
  end

  def handle_event("diff-search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :diff_search, q)}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    {:noreply, update(socket, :diff_sort, &SsmWeb.TableSort.toggle(&1, key))}
  end

  def handle_event("recheck-row", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.hosts, &(&1.id == String.to_integer(id))) do
      %Host{disabled: false} = host ->
        {:noreply,
         socket
         |> update(:statuses, &Map.put(&1, host.id, :loading))
         |> start_statuses_async([host])}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("sync-row", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.hosts, &(&1.id == String.to_integer(id))) do
      %Host{disabled: false} = host ->
        {:noreply,
         socket
         |> assign(:syncing, true)
         |> start_async(:sync, fn -> {host, Diffs.sync_host(host.id)} end)}

      %Host{disabled: true} = host ->
        {:noreply, put_flash(socket, :error, "Host #{host.name} is disabled.")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("recheck", _params, socket) do
    hosts = Enum.reject(socket.assigns.hosts, & &1.disabled)

    statuses =
      Enum.reduce(hosts, socket.assigns.statuses, &Map.put(&2, &1.id, :loading))

    {:noreply,
     socket
     |> assign(:statuses, statuses)
     |> start_statuses_async(hosts)}
  end

  def handle_event("sync", _params, socket) do
    case socket.assigns.selected do
      %Host{disabled: false} = host ->
        {:noreply,
         socket
         |> assign(:syncing, true)
         |> start_async(:sync, fn -> {host, Diffs.sync_host(host.id)} end)}

      %Host{disabled: true} = host ->
        {:noreply, put_flash(socket, :error, "Host #{host.name} is disabled.")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("allow-key", %{"login" => login, "index" => index}, socket) do
    with %Host{disabled: false} = host <- socket.assigns.selected,
         {:ok, item} <- find_extra_item(socket, login, index),
         {:ok, parsed} <- KeyParser.parse(item.line),
         %UserKey{} = key <- Users.get_key_by_base64(parsed.key_base64) do
      allow_grant(socket, host, key.user, login)
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot authorize this key.")}
    end
  end

  def handle_event("unknown-key-open", %{"login" => login, "index" => index}, socket) do
    with %Host{disabled: false} <- socket.assigns.selected,
         {:ok, item} <- find_extra_item(socket, login, index),
         {:ok, parsed} <- KeyParser.parse(item.line) do
      {:noreply,
       assign(socket, :unknown_key, %{
         login: login,
         line: item.line,
         parsed: parsed,
         users: Users.list_users()
       })}
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot assign this key.")}
    end
  end

  def handle_event("unknown-key-cancel", _params, socket) do
    {:noreply, assign(socket, :unknown_key, nil)}
  end

  def handle_event("unknown-key-assign", %{"assign" => %{"user_id" => user_id}}, socket) do
    with %Host{disabled: false} = host <- socket.assigns.selected,
         %{} = unknown <- socket.assigns.unknown_key,
         {:ok, id} <- parse_id(user_id),
         user when user != nil <- Users.get_user(id) do
      assign_unknown_key(socket, host, user, unknown)
    else
      _ -> {:noreply, put_flash(socket, :error, "Select a user to assign this key to.")}
    end
  end

  def handle_event("sync_all", _params, socket) do
    to_sync =
      socket.assigns.hosts
      |> Enum.reject(& &1.disabled)
      |> Enum.filter(fn host ->
        match?({:needs_sync, _, _}, socket.assigns.statuses[host.id])
      end)

    if to_sync == [] do
      {:noreply, put_flash(socket, :info, "Nothing to sync.")}
    else
      {:noreply,
       socket
       |> assign(:syncing, true)
       |> start_async(:sync_all, fn ->
         Enum.map(to_sync, fn host -> {host, Diffs.sync_host(host.id)} end)
       end)}
    end
  end

  ## Allow / assign helpers (database-only; the host is untouched until sync)

  defp find_extra_item(socket, login_name, index) do
    with %HostDiff{} = detail <- socket.assigns.detail,
         {:ok, position} <- parse_id(index),
         %{items: items} <- Enum.find(detail.logins, &(&1.login == login_name)),
         %{status: :extra_on_host} = item <- Enum.at(items, position) do
      {:ok, item}
    else
      _ -> :error
    end
  end

  # Event params are integers in our own markup; a malformed value must yield
  # a flash, not a crashed LiveView.
  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp allow_grant(socket, host, user, login) do
    if Authorizations.exists?(user.id, host.id, login) do
      {:noreply, put_flash(socket, :info, "#{user.username} already holds this grant.")}
    else
      case Authorizations.create_authorization(%{
             user_id: user.id,
             host_id: host.id,
             login: login
           }) do
        {:ok, _auth} ->
          log_allow(socket, user, host, login)

          {:noreply,
           socket
           |> put_flash(:info, "Authorized #{user.username} for #{login} on #{host.name}.")
           |> start_detail_async(host)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not create the authorization.")}
      end
    end
  end

  defp assign_unknown_key(socket, host, user, unknown) do
    case create_or_adopt_key(user, unknown.parsed) do
      {:ok, key} ->
        log_key_assign(socket, user, key)
        {_reply, socket} = allow_grant(socket, host, user, unknown.login)
        {:noreply, assign(socket, :unknown_key, nil)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # The key may already exist in the DB (assigned to someone) — then it is
  # adopted as-is instead of failing, mirroring the React DiffPage.
  defp create_or_adopt_key(user, parsed) do
    attrs = %{
      user_id: user.id,
      key_type: parsed.key_type,
      key_base64: parsed.key_base64,
      name: parsed.name
    }

    case Users.create_key(attrs) do
      {:ok, key} ->
        {:ok, key}

      {:error, changeset} ->
        case {changeset.errors[:key_base64], Users.get_key_by_base64(parsed.key_base64)} do
          {{"has already been taken", _}, %UserKey{} = key} -> {:ok, key}
          _ -> {:error, "Could not save the key — check the key line."}
        end
    end
  end

  defp log_allow(socket, user, host, login) do
    Activity.log(%{
      activity_type: "auth",
      action: "create",
      target: "#{user.username}@#{host.name}:#{login}",
      actor_username: socket.assigns.current_user.username,
      user_id: user.id
    })
  end

  defp log_key_assign(socket, user, key) do
    Activity.log(%{
      activity_type: "key",
      action: "create",
      target: key.name || key.key_type,
      actor_username: socket.assigns.current_user.username,
      user_id: user.id,
      details: %{key_type: key.key_type}
    })
  end

  # {:known, user} | :unknown | :invalid for an extra_on_host line.
  defp extra_key_info(line, owners) do
    case KeyParser.parse(line) do
      {:ok, parsed} ->
        case Map.get(owners, parsed.key_base64) do
          nil -> :unknown
          user -> {:known, user}
        end

      {:error, _reason} ->
        :invalid
    end
  end

  ## Helpers

  defp log_sync(socket, host, details) do
    Activity.log(%{
      activity_type: "host",
      action: "sync",
      target: host.name,
      actor_username: socket.assigns.current_user.username,
      details: details
    })
  end

  defp format_reason({_code, message}) when is_binary(message), do: message
  defp format_reason(:not_found), do: "host not found"
  defp format_reason(other), do: inspect(other)

  # Hosts for the list view: searched (name/address) and sorted.
  defp list_rows(assigns) do
    assigns.hosts
    |> filter_hosts(assigns.diff_search)
    |> SsmWeb.TableSort.sort(assigns.diff_sort, diff_sorters(assigns.statuses))
  end

  defp filter_hosts(hosts, search) do
    case search |> String.trim() |> String.downcase() do
      "" ->
        hosts

      needle ->
        Enum.filter(hosts, fn host ->
          String.contains?(String.downcase("#{host.name} #{host.address}"), needle)
        end)
    end
  end

  defp diff_sorters(statuses) do
    %{
      "name" => &SsmWeb.TableSort.string(&1.name),
      "address" => &{SsmWeb.TableSort.string(&1.address), &1.port},
      "status" => &diff_status_rank(statuses[&1.id]),
      "differences" => &(-(diff_count(statuses[&1.id]) || -1))
    }
  end

  defp diff_status_rank({:error, _}), do: 0
  defp diff_status_rank({:needs_sync, _, _}), do: 1
  defp diff_status_rank(:synced), do: 2
  defp diff_status_rank(:loading), do: 3
  defp diff_status_rank(:disabled), do: 4

  defp diff_count({:needs_sync, missing, extra}), do: missing + extra
  defp diff_count(:synced), do: 0
  defp diff_count(_status), do: nil

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]}>{status_text(@status)}</span>
    """
  end

  defp status_class(:disabled), do: "badge-neutral"
  defp status_class(:loading), do: "badge-ghost"
  defp status_class(:synced), do: "badge-success"
  defp status_class({:needs_sync, _, _}), do: "badge-warning"
  defp status_class({:error, _}), do: "badge-error"

  defp status_text(:disabled), do: "disabled"
  defp status_text(:loading), do: "checking…"
  defp status_text(:synced), do: "synchronized"
  defp status_text({:needs_sync, missing, extra}), do: "needs sync (+#{missing}/−#{extra})"
  defp status_text({:error, _}), do: "error"

  defp item_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs flex-none", item_class(@status)]}>{item_text(@status)}</span>
    """
  end

  defp item_class(:present), do: "badge-success"
  defp item_class(:missing_on_host), do: "badge-warning"
  defp item_class(:extra_on_host), do: "badge-error"

  defp item_text(:present), do: "present"
  defp item_text(:missing_on_host), do: "missing on host"
  defp item_text(:extra_on_host), do: "not authorized"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:diff}>
      <.header>
        Diff Viewer
        <:subtitle>Expected authorized_keys (database) vs actual (host)</:subtitle>
        <:actions>
          <.button id="recheck-all" phx-click="recheck" disabled={@syncing}>
            <.icon name="hero-arrow-path" class="size-4" /> Re-check all
          </.button>
          <.button id="sync-all" phx-click="sync_all" disabled={@syncing}>
            <.icon
              name="hero-cloud-arrow-up"
              class={["size-4", @syncing && "motion-safe:animate-spin"]}
            /> Sync all
          </.button>
        </:actions>
      </.header>

      <p :if={@hosts == []} class="text-sm opacity-60">No hosts configured.</p>

      <div class="flex flex-wrap items-center gap-3">
        <div id="diff-view-switcher" class="join">
          <button
            id="diff-view-cards"
            class={["btn btn-sm join-item", @diff_view == "cards" && "btn-primary"]}
            phx-click="diff-view"
            phx-value-view="cards"
          >
            <.icon name="hero-squares-2x2" class="size-4" /> Cards
          </button>
          <button
            id="diff-view-list"
            class={["btn btn-sm join-item", @diff_view == "list" && "btn-primary"]}
            phx-click="diff-view"
            phx-value-view="list"
          >
            <.icon name="hero-bars-3" class="size-4" /> List
          </button>
        </div>
        <form
          :if={@diff_view == "list"}
          id="diff-search"
          phx-change="diff-search"
          class="w-64"
        >
          <input
            type="search"
            name="q"
            value={@diff_search}
            placeholder="Search hosts by name or address…"
            class="input input-sm w-full"
            phx-debounce="200"
            autocomplete="off"
          />
        </form>
      </div>

      <div :if={@diff_view == "list" and @hosts != []} class="overflow-x-auto">
        <.table
          id="diff-list"
          rows={list_rows(assigns)}
          sort={@diff_sort}
          row_id={&"diff-row-#{&1.id}"}
          row_item={&Function.identity/1}
          row_click={&JS.push("select", value: %{id: &1.id})}
        >
          <:col :let={host} label="Name" sort="name">
            <span class="font-medium">{host.name}</span>
            <p :if={host.comment} class="text-xs opacity-60">{host.comment}</p>
          </:col>
          <:col :let={host} label="Address" sort="address">{host.address}:{host.port}</:col>
          <:col :let={host} label="Status" sort="status">
            <.status_badge status={@statuses[host.id]} />
          </:col>
          <:col :let={host} label="Differences" sort="differences">
            <span
              :if={diff_count(@statuses[host.id])}
              class={[
                "tabular-nums",
                (diff_count(@statuses[host.id]) > 0 && "font-medium text-warning") || "opacity-60"
              ]}
            >
              {diff_count(@statuses[host.id])} difference(s)
            </span>
            <span :if={is_nil(diff_count(@statuses[host.id]))} class="opacity-40">—</span>
          </:col>
          <:action :let={host}>
            <button
              id={"recheck-row-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="recheck-row"
              phx-value-id={host.id}
              disabled={host.disabled}
              title="Re-check this host"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
            <button
              id={"sync-row-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="sync-row"
              phx-value-id={host.id}
              disabled={host.disabled || @syncing}
              data-confirm={"Sync #{host.name}? This writes the expected authorized_keys to the host."}
              title="Sync this host"
            >
              <.icon name="hero-cloud-arrow-up" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <ul
        :if={@diff_view == "cards"}
        id="diff-hosts"
        class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
      >
        <li :for={host <- @hosts}>
          <button
            id={"diff-host-#{host.id}"}
            class={[
              "flex w-full items-center justify-between gap-2 rounded-box bg-base-200 px-4 py-3",
              "text-left transition hover:bg-base-300",
              @selected && @selected.id == host.id && "ring-2 ring-primary"
            ]}
            phx-click="select"
            phx-value-id={host.id}
          >
            <span class="min-w-0">
              <span class="block truncate font-medium">{host.name}</span>
              <span class="block truncate text-xs opacity-60">{host.address}:{host.port}</span>
            </span>
            <.status_badge status={@statuses[host.id]} />
          </button>
        </li>
      </ul>

      <section :if={@selected} id="diff-detail" class="card bg-base-200">
        <div class="card-body">
          <div class="flex items-center justify-between gap-4">
            <h2 class="card-title text-base">
              {@selected.name}
              <.status_badge status={@statuses[@selected.id]} />
            </h2>
            <div class="flex gap-2">
              <button
                id="refresh-diff"
                class="btn btn-ghost btn-sm"
                phx-click="refresh"
                disabled={@selected.disabled || @detail_loading}
              >
                <.icon
                  name="hero-arrow-path"
                  class={["size-4", @detail_loading && "motion-safe:animate-spin"]}
                /> Refresh
              </button>
              <button
                id="sync-host"
                class="btn btn-primary btn-sm"
                phx-click="sync"
                disabled={@selected.disabled || @syncing || @detail_loading}
              >
                <.icon name="hero-cloud-arrow-up" class="size-4" /> Sync
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="deselect" aria-label="Close detail">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>

          <p :if={@selected.disabled} class="text-sm opacity-70">
            Host is disabled — no diff operations available.
          </p>

          <div :if={@detail_error} class="alert alert-error text-sm" id="diff-detail-error">
            <.icon name="hero-exclamation-triangle" class="size-4" />
            {@detail_error}
          </div>

          <p :if={@detail_loading && !@detail} class="text-sm opacity-60">Loading diff…</p>

          <div :for={login <- (@detail && @detail.logins) || []} class="space-y-1">
            <div class="flex items-center gap-2 pt-2">
              <.icon name="hero-user-circle" class="size-4 opacity-70" />
              <span class="font-mono text-sm font-medium">{login.login}</span>
              <span :if={login.has_pragma} class="badge badge-ghost badge-xs">managed</span>
              <span :if={login.readonly_condition} class="badge badge-error badge-xs">
                readonly: {login.readonly_condition}
              </span>
            </div>

            <div :if={login.read_error} class="alert alert-warning py-2 text-xs">
              read failed: {login.read_error}
            </div>

            <p :if={login.items == []} class="text-xs opacity-60">No keys expected or present.</p>

            <ul class="space-y-1">
              <li
                :for={{item, index} <- Enum.with_index(login.items)}
                class="flex items-center gap-2 rounded bg-base-100 px-2 py-1"
              >
                <.item_badge status={item.status} />
                <code class="truncate font-mono text-xs" title={item.line}>{item.line}</code>
                <.extra_key_actions
                  :if={item.status == :extra_on_host and not @selected.disabled}
                  info={extra_key_info(item.line, @key_owners)}
                  login={login.login}
                  index={index}
                />
              </li>
            </ul>
          </div>
        </div>
      </section>

      <.modal :if={@unknown_key} id="unknown-key-modal" on_cancel={JS.push("unknown-key-cancel")}>
        <:title>Assign unknown key</:title>

        <p class="mb-2 text-sm opacity-70">
          This key is not in the database. Assign it to a user; the user is also
          granted login <span class="font-mono">{@unknown_key.login}</span>
          on this host if missing. The host itself is only changed by a later sync.
        </p>

        <pre class="mb-2 max-h-24 overflow-auto whitespace-pre-wrap break-all rounded bg-base-300 p-2 font-mono text-xs">{@unknown_key.line}</pre>

        <form id="unknown-key-form" phx-submit="unknown-key-assign" class="space-y-2">
          <.input
            type="select"
            name="assign[user_id]"
            value={nil}
            label="Assign to user"
            prompt="Select a user"
            options={Enum.map(@unknown_key.users, &{&1.username, &1.id})}
            required
          />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="unknown-key-cancel">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Assign key</button>
          </div>
        </form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :info, :any, required: true
  attr :login, :string, required: true
  attr :index, :integer, required: true

  defp extra_key_actions(%{info: {:known, _user}} = assigns) do
    ~H"""
    <button
      id={"allow-key-#{@login}-#{@index}"}
      class="btn btn-ghost btn-xs ml-auto flex-none text-success"
      phx-click="allow-key"
      phx-value-login={@login}
      phx-value-index={@index}
      title={"Authorize #{elem(@info, 1).username} for #{@login} (database only)"}
    >
      <.icon name="hero-check-circle" class="size-4" /> Allow ({elem(@info, 1).username})
    </button>
    """
  end

  defp extra_key_actions(%{info: :unknown} = assigns) do
    ~H"""
    <button
      id={"assign-key-#{@login}-#{@index}"}
      class="btn btn-ghost btn-xs ml-auto flex-none"
      phx-click="unknown-key-open"
      phx-value-login={@login}
      phx-value-index={@index}
      title="Key is unknown — assign it to a user"
    >
      <.icon name="hero-user-plus" class="size-4" /> Add key…
    </button>
    """
  end

  defp extra_key_actions(assigns), do: ~H""
end
