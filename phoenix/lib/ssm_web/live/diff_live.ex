defmodule SsmWeb.DiffLive do
  @moduledoc """
  Diff viewer: per-host comparison of the DB's expected authorized_keys
  against what is on the host, with single-host sync and sync-all — the
  React DiffPage core. Disabled hosts are marked and never touched
  (non-negotiable rule #4); readonly logins surface as badges and sync
  refusals, never partial writes (`Ssm.Diffs.sync_host/2` semantics).
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Diffs
  alias Ssm.Diffs.HostDiff
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    hosts = Hosts.list_hosts()

    statuses =
      Map.new(hosts, fn host ->
        {host.id, if(host.disabled, do: :disabled, else: :loading)}
      end)

    socket =
      socket
      |> assign(page_title: "Diff Viewer")
      |> assign(hosts: hosts, statuses: statuses, syncing: false)
      |> assign(detail: nil, detail_error: nil, detail_loading: false)

    socket =
      if connected?(socket) do
        start_statuses_async(socket, Enum.reject(hosts, & &1.disabled))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected =
      with raw when is_binary(raw) <- params["host_id"],
           {id, ""} <- Integer.parse(raw) do
        Enum.find(socket.assigns.hosts, &(&1.id == id))
      else
        _ -> nil
      end

    socket = assign(socket, selected: selected, detail: nil, detail_error: nil)

    socket =
      if (connected?(socket) and selected) && !selected.disabled do
        start_detail_async(socket, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Async work

  defp start_statuses_async(socket, hosts) do
    ids = Enum.map(hosts, & &1.id)

    start_async(socket, :statuses, fn ->
      ids
      |> Task.async_stream(&{&1, status_for(&1)},
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, pair} -> pair end)
      |> Map.new()
    end)
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
  def handle_async(:statuses, {:ok, results}, socket) do
    {:noreply, update(socket, :statuses, &Map.merge(&1, results))}
  end

  def handle_async(:statuses, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Status check crashed: #{inspect(reason)}")}
  end

  def handle_async(:detail, {:ok, result}, socket) do
    socket = assign(socket, :detail_loading, false)

    case result do
      {:ok, %HostDiff{} = diff} ->
        statuses = Map.put(socket.assigns.statuses, diff.host_id, summarize(diff))
        {:noreply, assign(socket, detail: diff, detail_error: nil, statuses: statuses)}

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
    {:noreply, push_patch(socket, to: ~p"/diff?host_id=#{id}")}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff")}
  end

  def handle_event("refresh", _params, socket) do
    case socket.assigns.selected do
      %Host{disabled: false} = host -> {:noreply, start_detail_async(socket, host)}
      _ -> {:noreply, socket}
    end
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
          <.button id="sync-all" phx-click="sync_all" disabled={@syncing}>
            <.icon name="hero-arrow-path" class={["size-4", @syncing && "motion-safe:animate-spin"]} />
            Sync all
          </.button>
        </:actions>
      </.header>

      <p :if={@hosts == []} class="text-sm opacity-60">No hosts configured.</p>

      <ul id="diff-hosts" class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
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
                :for={item <- login.items}
                class="flex items-center gap-2 rounded bg-base-100 px-2 py-1"
              >
                <.item_badge status={item.status} />
                <code class="truncate font-mono text-xs" title={item.line}>{item.line}</code>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
