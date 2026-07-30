defmodule SsmWeb.HostsLive do
  @moduledoc """
  Hosts page: list, create/edit modal, enable/disable, delete, and an async
  SSH connection test — parity with the React HostsPage. Every SSH action
  checks `host.disabled` first (non-negotiable rule #4).
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Hosts")
     |> assign(form: nil, editing: nil, testing_id: nil)
     |> reload_hosts()}
  end

  defp reload_hosts(socket) do
    hosts = Hosts.list_hosts()

    socket
    |> assign(:host_count, length(hosts))
    |> assign(:host_names, Map.new(hosts, &{&1.id, &1.name}))
    |> stream(:hosts, hosts, reset: true)
  end

  ## Events

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       form: to_form(Hosts.change_host(%Host{})),
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
         |> start_async(:test_connection, fn -> {host.name, Ssm.Ssh.connect(target)} end)}
    end
  end

  @impl true
  def handle_async(:test_connection, {:ok, {name, result}}, socket) do
    socket = assign(socket, :testing_id, nil)

    case result do
      :ok ->
        {:noreply, put_flash(socket, :info, "Connection to #{name} succeeded.")}

      {:error, {_code, message}} ->
        {:noreply, put_flash(socket, :error, "Connection to #{name} failed: #{message}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Connection to #{name} failed: #{inspect(reason)}")}
    end
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:testing_id, nil)
     |> put_flash(:error, "Connection test crashed: #{inspect(reason)}")}
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

      <p :if={@host_count == 0} class="text-sm opacity-60">
        No hosts yet — create the first one.
      </p>

      <div :if={@host_count > 0} class="overflow-x-auto">
        <.table id="hosts" rows={@streams.hosts}>
          <:col :let={{_id, host}} label="Name">
            <span class="font-medium">{host.name}</span>
            <p :if={host.comment} class="text-xs opacity-60">{host.comment}</p>
          </:col>
          <:col :let={{_id, host}} label="Address">{host.address}:{host.port}</:col>
          <:col :let={{_id, host}} label="Login">{host.username}</:col>
          <:col :let={{_id, host}} label="Jump via">
            {(host.jump_via && Map.get(@host_names, host.jump_via)) || "—"}
          </:col>
          <:col :let={{_id, host}} label="Status">
            <span class={["badge badge-sm", (host.disabled && "badge-error") || "badge-success"]}>
              {if host.disabled, do: "disabled", else: "enabled"}
            </span>
          </:col>
          <:action :let={{_id, host}}>
            <button
              id={"test-host-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="test_connection"
              phx-value-id={host.id}
              disabled={@testing_id != nil}
              title="Test SSH connection"
            >
              <.icon
                name={
                  if @testing_id == host.id,
                    do: "hero-arrow-path",
                    else: "hero-signal"
                }
                class={["size-4", @testing_id == host.id && "motion-safe:animate-spin"]}
              />
            </button>
            <button
              id={"toggle-host-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="toggle_disabled"
              phx-value-id={host.id}
              title={if host.disabled, do: "Enable host", else: "Disable host"}
            >
              <.icon name={if host.disabled, do: "hero-play", else: "hero-pause"} class="size-4" />
            </button>
            <button
              id={"edit-host-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="edit"
              phx-value-id={host.id}
              title="Edit host"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              id={"delete-host-#{host.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-id={host.id}
              data-confirm={"Delete host #{host.name}? Its authorizations go with it."}
              title="Delete host"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <.modal :if={@form} id="host-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit host", else: "New host"}</:title>

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
      </.modal>
    </Layouts.app>
    """
  end
end
