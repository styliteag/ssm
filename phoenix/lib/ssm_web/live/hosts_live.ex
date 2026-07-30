defmodule SsmWeb.HostsLive do
  @moduledoc """
  Hosts page: list with online/offline badges, status filter pills,
  create/edit modal, enable/disable, delete, an async SSH connection test,
  and cross-links (authorization count → authorizations page, diff link per
  host) — the React HostsPage. Every SSH action checks `host.disabled`
  first (non-negotiable rule #4).

  Online/offline is fed from two sources: the diff viewer's `StatusCache`
  (a host whose keys were readable is online) and this page's own
  connection tests. Rows are a plain assign, not a stream — filtering and
  status overlays must re-render rows.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Authorizations
  alias Ssm.Diffs.StatusCache
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Layouts

  @filters ~w(active all online offline unknown disabled)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Hosts")
     |> assign(form: nil, editing: nil, testing_id: nil)
     |> assign(filter: "active", conn_results: %{}, sort: nil, view: "list")
     |> reload_hosts()}
  end

  defp reload_hosts(socket) do
    hosts = Hosts.list_hosts()

    socket
    |> assign(:all_hosts, hosts)
    |> assign(:host_names, Map.new(hosts, &{&1.id, &1.name}))
    |> assign(
      :auth_counts,
      Enum.frequencies_by(Authorizations.list_authorizations(), & &1.host_id)
    )
    |> refilter()
  end

  defp refilter(socket) do
    %{all_hosts: hosts, conn_results: conn_results, filter: filter} = socket.assigns

    cached = StatusCache.all()
    statuses = Map.new(hosts, &{&1.id, host_status(&1, conn_results, cached)})

    rows =
      hosts
      |> Enum.filter(&matches_filter?(filter, &1, statuses[&1.id]))
      |> SsmWeb.TableSort.sort(socket.assigns.sort, host_sorters(socket.assigns, statuses))

    socket
    |> assign(:statuses, statuses)
    |> assign(:rows, rows)
    |> assign(:host_count, length(hosts))
  end

  defp host_sorters(assigns, statuses) do
    %{
      "name" => &SsmWeb.TableSort.string(&1.name),
      "address" => &{SsmWeb.TableSort.string(&1.address), &1.port},
      "login" => &SsmWeb.TableSort.string(&1.username),
      "jump" => &SsmWeb.TableSort.string(&1.jump_via && assigns.host_names[&1.jump_via]),
      "access" => &Map.get(assigns.auth_counts, &1.id, 0),
      "status" => &status_rank(statuses[&1.id])
    }
  end

  defp status_rank(:online), do: 0
  defp status_rank({:offline, _message}), do: 1
  defp status_rank(:unknown), do: 2
  defp status_rank(:disabled), do: 3

  # disabled beats everything; an explicit connection test beats the diff
  # sweep's cached result; no signal at all is "unknown" (React parity).
  defp host_status(%Host{disabled: true}, _conn_results, _cached), do: :disabled

  defp host_status(host, conn_results, cached) do
    case {conn_results[host.id], cached[host.id]} do
      {:online, _} -> :online
      {{:offline, message}, _} -> {:offline, message}
      {nil, {:synced, _at}} -> :online
      {nil, {{:needs_sync, _, _}, _at}} -> :online
      {nil, {{:error, message}, _at}} -> {:offline, message}
      _ -> :unknown
    end
  end

  defp matches_filter?("active", host, _status), do: not host.disabled
  defp matches_filter?("all", _host, _status), do: true
  defp matches_filter?("online", _host, status), do: status == :online
  defp matches_filter?("offline", _host, status), do: match?({:offline, _}, status)
  defp matches_filter?("unknown", _host, status), do: status == :unknown
  defp matches_filter?("disabled", _host, status), do: status == :disabled

  defp pill_count(hosts, statuses, filter) do
    Enum.count(hosts, &matches_filter?(filter, &1, statuses[&1.id]))
  end

  ## Events

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) when filter in @filters do
    {:noreply, socket |> assign(:filter, filter) |> refilter()}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    sort = SsmWeb.TableSort.toggle(socket.assigns.sort, key)
    {:noreply, socket |> assign(:sort, sort) |> refilter()}
  end

  def handle_event("view-mode", %{"view" => view}, socket) when view in ~w(list cards) do
    {:noreply, assign(socket, :view, view)}
  end

  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       # SSH login pre-filled with root — the overwhelmingly common case
       # (React HostsPage default since 1.1.0).
       form: to_form(Hosts.change_host(%Host{}, %{"username" => "root"})),
       editing: nil,
       jump_candidates: Hosts.jump_candidates(nil)
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Hosts.get_host(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      host ->
        {:noreply,
         assign(socket,
           form: to_form(Hosts.change_host(host)),
           editing: host,
           jump_candidates: Hosts.jump_candidates(host)
         )}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: nil)}
  end

  def handle_event("validate", %{"host" => params}, socket) do
    changeset =
      (socket.assigns.editing || %Host{})
      |> Hosts.change_host(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"host" => params}, socket) do
    params = normalize_params(params)

    result =
      case socket.assigns.editing do
        nil -> Hosts.create_host(params)
        host -> Hosts.update_host(host, params)
      end

    case result do
      {:ok, host} ->
        action = if socket.assigns.editing, do: "update", else: "create"
        log_host_activity(socket, action, host)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Host #{host.name} #{action}d.")
         |> reload_hosts()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Host{} = host <- Hosts.get_host(String.to_integer(id)),
         {:ok, _} <- Hosts.delete_host(host) do
      log_host_activity(socket, "delete", host)
      StatusCache.delete(host.id)

      {:noreply,
       socket
       |> put_flash(:info, "Host #{host.name} deleted.")
       |> reload_hosts()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot delete this host: it is still referenced (authorizations or jump chains)."
         )}
    end
  end

  def handle_event("toggle_disabled", %{"id" => id}, socket) do
    with %Host{} = host <- Hosts.get_host(String.to_integer(id)),
         {:ok, updated} <- Hosts.update_host(host, %{disabled: !host.disabled}) do
      action = if updated.disabled, do: "disable", else: "enable"
      log_host_activity(socket, action, updated)

      {:noreply,
       socket
       |> put_flash(:info, "Host #{updated.name} #{action}d.")
       |> reload_hosts()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Host not found.")}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    case Hosts.get_host(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      %Host{disabled: true} = host ->
        {:noreply, put_flash(socket, :error, "Host #{host.name} is disabled.")}

      host ->
        target = Hosts.target_for(host)

        {:noreply,
         socket
         |> assign(:testing_id, host.id)
         |> start_async(:test_connection, fn -> {host, Ssm.Ssh.connect(target)} end)}
    end
  end

  @impl true
  def handle_async(:test_connection, {:ok, {host, result}}, socket) do
    socket = assign(socket, :testing_id, nil)

    case result do
      :ok ->
        {:noreply,
         socket
         |> put_conn_result(host.id, :online)
         |> put_flash(:info, "Connection to #{host.name} succeeded.")}

      {:error, {_code, message}} ->
        {:noreply,
         socket
         |> put_conn_result(host.id, {:offline, message})
         |> put_flash(:error, "Connection to #{host.name} failed: #{message}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_conn_result(host.id, {:offline, inspect(reason)})
         |> put_flash(:error, "Connection to #{host.name} failed: #{inspect(reason)}")}
    end
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:testing_id, nil)
     |> put_flash(:error, "Connection test crashed: #{inspect(reason)}")}
  end

  defp put_conn_result(socket, host_id, result) do
    socket
    |> update(:conn_results, &Map.put(&1, host_id, result))
    |> refilter()
  end

  ## Helpers

  # A cleared select posts `""`; Ecto's cast treats `""` as a missing value
  # rather than an explicit nil, so map it here (the jump_via pattern).
  defp normalize_params(params) do
    Map.update(params, "jump_via", nil, fn
      "" -> nil
      value -> value
    end)
  end

  defp log_host_activity(socket, action, host) do
    Activity.log(%{
      activity_type: "host",
      action: action,
      target: host.name,
      actor_username: socket.assigns.current_user.username,
      details: %{address: host.address, port: host.port}
    })
  end

  defp status_label(:online), do: "online"
  defp status_label({:offline, _message}), do: "offline"
  defp status_label(:unknown), do: "unknown"
  defp status_label(:disabled), do: "disabled"

  defp status_class(:online), do: "badge-success"
  defp status_class({:offline, _message}), do: "badge-error"
  defp status_class(:unknown), do: "badge-ghost"
  defp status_class(:disabled), do: "badge-neutral"

  defp status_title({:offline, message}), do: message
  defp status_title(:online), do: "Reachable (last diff check or connection test)"
  defp status_title(:unknown), do: "Not checked yet — run the diff viewer or a connection test"
  defp status_title(:disabled), do: "Disabled — all SSH operations blocked"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:hosts}>
      <.header>
        Hosts
        <:subtitle>{@host_count} managed SSH hosts</:subtitle>
        <:actions>
          <.button id="new-host" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New host
          </.button>
        </:actions>
      </.header>

      <div id="host-filters" class="flex flex-wrap gap-2">
        <button
          :for={
            {filter, label} <- [
              {"active", "Active"},
              {"all", "All"},
              {"online", "Online"},
              {"offline", "Offline"},
              {"unknown", "Unknown"},
              {"disabled", "Disabled"}
            ]
          }
          id={"filter-#{filter}"}
          type="button"
          class={[
            "btn btn-xs rounded-full",
            if(@filter == filter, do: "btn-primary", else: "btn-ghost")
          ]}
          phx-click="filter"
          phx-value-filter={filter}
        >
          {label} ({pill_count(@all_hosts, @statuses, filter)})
        </button>
      </div>

      <p :if={@host_count == 0} class="text-sm opacity-60">
        No hosts yet — create the first one.
      </p>

      <.view_toggle id="hosts-view" view={@view} />

      <p :if={@host_count > 0 and @rows == []} class="text-sm opacity-60">
        No hosts match this filter.
      </p>

      <ul :if={@view == "cards" and @rows != []} class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <li
          :for={host <- @rows}
          id={"host-card-#{host.id}"}
          class="rounded-box bg-base-200 px-4 py-3"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="min-w-0">
              <span class="block truncate font-medium">{host.name}</span>
              <span class="block truncate text-xs opacity-60">{host.address}:{host.port}</span>
            </span>
            <span
              class={["badge badge-sm flex-none", status_class(@statuses[host.id])]}
              title={status_title(@statuses[host.id])}
            >
              {status_label(@statuses[host.id])}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs opacity-70">
            <span>login {host.username}</span>
            <span :if={host.jump_via}>via {Map.get(@host_names, host.jump_via)}</span>
            <.link
              navigate={~p"/authorizations?host_id=#{host.id}"}
              class="link link-hover"
              title="Authorizations on this host"
            >
              {Map.get(@auth_counts, host.id, 0)} grant(s)
            </.link>
          </div>
          <p :if={host.comment} class="mt-1 truncate text-xs opacity-60">{host.comment}</p>
          <div class="mt-2 flex gap-1">
            <.host_actions host={host} testing_id={@testing_id} />
          </div>
        </li>
      </ul>

      <div :if={@view == "list" and @rows != []} class="overflow-x-auto">
        <.table
          id="hosts"
          rows={@rows}
          sort={@sort}
          row_id={&"hosts-#{&1.id}"}
          row_item={&Function.identity/1}
        >
          <:col :let={host} label="Name" sort="name">
            <span class="font-medium">{host.name}</span>
            <p :if={host.comment} class="text-xs opacity-60">{host.comment}</p>
          </:col>
          <:col :let={host} label="Address" sort="address">{host.address}:{host.port}</:col>
          <:col :let={host} label="Login" sort="login">{host.username}</:col>
          <:col :let={host} label="Jump via" sort="jump">
            {(host.jump_via && Map.get(@host_names, host.jump_via)) || "—"}
          </:col>
          <:col :let={host} label="Access" sort="access">
            <.link
              navigate={~p"/authorizations?host_id=#{host.id}"}
              class="link link-hover tabular-nums"
              title="Authorizations on this host"
            >
              {Map.get(@auth_counts, host.id, 0)}
            </.link>
          </:col>
          <:col :let={host} label="Status" sort="status">
            <span
              class={["badge badge-sm", status_class(@statuses[host.id])]}
              title={status_title(@statuses[host.id])}
            >
              {status_label(@statuses[host.id])}
            </span>
          </:col>
          <:action :let={host}>
            <.host_actions host={host} testing_id={@testing_id} />
          </:action>
        </.table>
      </div>

      <.modal :if={@form} id="host-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit host", else: "New host"}</:title>
        <.host_modal_body form={@form} editing={@editing} jump_candidates={@jump_candidates} />
      </.modal>
    </Layouts.app>
    """
  end

  attr :host, :any, required: true
  attr :testing_id, :any, required: true

  defp host_actions(assigns) do
    ~H"""
    <.link
      id={"diff-link-#{@host.id}"}
      navigate={~p"/diff?host_id=#{@host.id}"}
      class="btn btn-ghost btn-xs"
      title="Open in diff viewer"
    >
      <.icon name="hero-arrows-right-left" class="size-4" />
    </.link>
    <button
      id={"test-host-#{@host.id}"}
      class="btn btn-ghost btn-xs"
      phx-click="test_connection"
      phx-value-id={@host.id}
      disabled={@testing_id != nil}
      title="Test SSH connection"
    >
      <.icon
        name={
          if @testing_id == @host.id,
            do: "hero-arrow-path",
            else: "hero-signal"
        }
        class={["size-4", @testing_id == @host.id && "motion-safe:animate-spin"]}
      />
    </button>
    <button
      id={"toggle-host-#{@host.id}"}
      class="btn btn-ghost btn-xs"
      phx-click="toggle_disabled"
      phx-value-id={@host.id}
      title={if @host.disabled, do: "Enable host", else: "Disable host"}
    >
      <.icon name={if @host.disabled, do: "hero-play", else: "hero-pause"} class="size-4" />
    </button>
    <button
      id={"edit-host-#{@host.id}"}
      class="btn btn-ghost btn-xs"
      phx-click="edit"
      phx-value-id={@host.id}
      title="Edit host"
    >
      <.icon name="hero-pencil-square" class="size-4" />
    </button>
    <button
      id={"delete-host-#{@host.id}"}
      class="btn btn-ghost btn-xs text-error"
      phx-click="delete"
      phx-value-id={@host.id}
      data-confirm={"Delete host #{@host.name}? Its authorizations go with it."}
      title="Delete host"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :jump_candidates, :list, required: true

  defp host_modal_body(assigns) do
    ~H"""
    <div>
      <.form for={@form} id="host-form" phx-change="validate" phx-submit="save" class="space-y-2">
        <.input field={@form[:name]} type="text" label="Name" required />
        <div class="grid grid-cols-3 gap-3">
          <div class="col-span-2">
            <.input field={@form[:address]} type="text" label="Address" required />
          </div>
          <.input field={@form[:port]} type="number" label="Port" required />
        </div>
        <.input field={@form[:username]} type="text" label="SSH login user" required />
        <.input
          field={@form[:jump_via]}
          type="select"
          label="Jump via"
          prompt="None (direct connection)"
          options={Enum.map(@jump_candidates, &{&1.name, &1.id})}
        />
        <.input field={@form[:comment]} type="text" label="Comment" />
        <.input field={@form[:disabled]} type="checkbox" label="Disabled (blocks all SSH)" />

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">
            {if @editing, do: "Save changes", else: "Create host"}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
