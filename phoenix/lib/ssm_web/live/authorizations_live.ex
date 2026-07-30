defmodule SsmWeb.AuthorizationsLive do
  @moduledoc """
  Authorizations page: user↔host grants under a remote login, filterable by
  user or host (`?user_id=` / `?host_id=`), with add/edit modal and delete —
  the React AuthorizationsPage core. Bulk grant is post-parity work.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Authorizations
  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts
  alias Ssm.Users
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Authorizations", form: nil, editing: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filter_user_id, parse_id(params["user_id"]))
     |> assign(:filter_host_id, parse_id(params["host_id"]))
     |> assign(:users, Users.list_users())
     |> assign(:hosts, Hosts.list_hosts())
     |> reload_authorizations()}
  end

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp reload_authorizations(socket) do
    opts =
      Enum.reject(
        [user_id: socket.assigns.filter_user_id, host_id: socket.assigns.filter_host_id],
        fn {_k, v} -> is_nil(v) end
      )

    authorizations = Authorizations.list_authorizations(opts)

    socket
    |> assign(:authorization_count, length(authorizations))
    |> stream(:authorizations, authorizations, reset: true)
  end

  ## Events

  @impl true
  def handle_event("filter", params, socket) do
    query =
      [user_id: params["user_id"], host_id: params["host_id"]]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/authorizations?#{query}")}
  end

  def handle_event("new", _params, socket) do
    attrs =
      %{}
      |> maybe_put("user_id", socket.assigns.filter_user_id)
      |> maybe_put("host_id", socket.assigns.filter_host_id)

    {:noreply,
     assign(socket,
       form: to_form(Authorizations.change_authorization(%Authorization{}, attrs)),
       editing: nil
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Authorizations.get_authorization(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Authorization not found.")}

      auth ->
        {:noreply,
         assign(socket,
           form: to_form(Authorizations.change_authorization(auth)),
           editing: auth
         )}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: nil)}
  end

  def handle_event("validate", %{"authorization" => params}, socket) do
    changeset =
      (socket.assigns.editing || %Authorization{})
      |> Authorizations.change_authorization(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"authorization" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Authorizations.create_authorization(params)
        auth -> Authorizations.update_authorization(auth, params)
      end

    case result do
      {:ok, auth} ->
        action = if socket.assigns.editing, do: "update", else: "create"
        log_auth_activity(socket, action, auth)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Authorization #{action}d.")
         |> reload_authorizations()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Authorization{} = auth <-
           Authorizations.get_authorization(String.to_integer(id)),
         {:ok, _} <- Authorizations.delete_authorization(auth) do
      log_auth_activity(socket, "delete", auth)

      {:noreply,
       socket
       |> put_flash(:info, "Authorization deleted.")
       |> reload_authorizations()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Authorization not found.")}
    end
  end

  ## Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp log_auth_activity(socket, action, auth) do
    auth = Ssm.Repo.preload(auth, [:user, :host])
    target = "#{auth.user.username}@#{auth.host.name}:#{auth.login}"

    attrs = %{
      activity_type: "auth",
      action: action,
      target: target,
      actor_username: socket.assigns.current_user.username
    }

    attrs = if action == "delete", do: attrs, else: Map.put(attrs, :user_id, auth.user_id)

    Activity.log(attrs)
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:authorizations}>
      <.header>
        Authorizations
        <:subtitle>{@authorization_count} grants (user → host under a login)</:subtitle>
        <:actions>
          <.button id="new-authorization" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New authorization
          </.button>
        </:actions>
      </.header>

      <form id="authorizations-filter" phx-change="filter" class="flex max-w-xl gap-3">
        <div class="flex-1">
          <.input
            type="select"
            name="user_id"
            value={@filter_user_id}
            label="Filter by user"
            prompt="All users"
            options={Enum.map(@users, &{&1.username, &1.id})}
          />
        </div>
        <div class="flex-1">
          <.input
            type="select"
            name="host_id"
            value={@filter_host_id}
            label="Filter by host"
            prompt="All hosts"
            options={Enum.map(@hosts, &{&1.name, &1.id})}
          />
        </div>
      </form>

      <p :if={@authorization_count == 0} class="text-sm opacity-60">No authorizations found.</p>

      <div :if={@authorization_count > 0} class="overflow-x-auto">
        <.table id="authorizations" rows={@streams.authorizations}>
          <:col :let={{_id, auth}} label="User">{auth.user.username}</:col>
          <:col :let={{_id, auth}} label="Host">{auth.host.name}</:col>
          <:col :let={{_id, auth}} label="Login">
            <span class="font-mono text-sm">{auth.login}</span>
          </:col>
          <:col :let={{_id, auth}} label="Options">
            <span class="font-mono text-xs">{auth.options || "—"}</span>
          </:col>
          <:col :let={{_id, auth}} label="Comment">{auth.comment || "—"}</:col>
          <:action :let={{_id, auth}}>
            <button
              id={"edit-authorization-#{auth.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="edit"
              phx-value-id={auth.id}
              title="Edit authorization"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              id={"delete-authorization-#{auth.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-id={auth.id}
              data-confirm={"Revoke access for #{auth.user.username} on #{auth.host.name} (login #{auth.login})?"}
              title="Delete authorization"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <.modal :if={@form} id="authorization-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit authorization", else: "New authorization"}</:title>

        <.form
          for={@form}
          id="authorization-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-2"
        >
          <.input
            field={@form[:user_id]}
            type="select"
            label="User"
            prompt="Select a user"
            options={Enum.map(@users, &{&1.username, &1.id})}
            required
          />
          <.input
            field={@form[:host_id]}
            type="select"
            label="Host"
            prompt="Select a host"
            options={Enum.map(@hosts, &{&1.name, &1.id})}
            required
          />
          <.input
            field={@form[:login]}
            type="text"
            label="Remote login"
            placeholder="e.g. deploy"
            required
          />
          <.input
            field={@form[:options]}
            type="text"
            label="authorized_keys options"
            placeholder={~s(e.g. no-pty,from="10.0.0.0/8")}
          />
          <.input field={@form[:comment]} type="text" label="Comment" />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Save changes", else: "Create authorization"}
            </button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
