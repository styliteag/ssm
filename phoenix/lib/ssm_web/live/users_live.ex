defmodule SsmWeb.UsersLive do
  @moduledoc """
  Users page: managed key owners with per-user key/authorization counts,
  create/edit modal, enable/disable toggle, and delete (cascades keys and
  authorizations, like the DB schema says) — parity with the React UsersPage
  core. Split/merge/bulk tooling from the React page is post-parity work.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Users
  alias Ssm.Users.User
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Users")
     |> assign(form: nil, editing: nil)
     |> reload_users()}
  end

  defp reload_users(socket) do
    rows =
      Users.list_users_with_counts()
      |> Enum.map(&Map.put(&1, :id, &1.user.id))

    socket
    |> assign(:user_count, length(rows))
    |> stream(:users, rows, reset: true)
  end

  ## Events

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, form: to_form(Users.change_user(%User{})), editing: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Users.get_user(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:noreply, assign(socket, form: to_form(Users.change_user(user)), editing: user)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: nil)}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      (socket.assigns.editing || %User{})
      |> Users.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Users.create_user(params)
        user -> Users.update_user(user, params)
      end

    case result do
      {:ok, user} ->
        action = if socket.assigns.editing, do: "update", else: "create"
        log_user_activity(socket, action, user)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "User #{user.username} #{action}d.")
         |> reload_users()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %User{} = user <- Users.get_user(String.to_integer(id)),
         {:ok, _} <- Users.delete_user(user) do
      log_user_activity(socket, "delete", user)

      {:noreply,
       socket
       |> put_flash(:info, "User #{user.username} deleted.")
       |> reload_users()}
    else
      _ -> {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with %User{} = user <- Users.get_user(String.to_integer(id)),
         {:ok, updated} <- Users.update_user(user, %{enabled: !user.enabled}) do
      action = if updated.enabled, do: "enable", else: "disable"
      log_user_activity(socket, action, updated)

      {:noreply,
       socket
       |> put_flash(:info, "User #{updated.username} #{action}d.")
       |> reload_users()}
    else
      _ -> {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  # "delete" must not reference the just-removed row (FK on activity_log.user_id).
  defp log_user_activity(socket, "delete" = action, user) do
    Activity.log(%{
      activity_type: "user",
      action: action,
      target: user.username,
      actor_username: socket.assigns.current_user.username
    })
  end

  defp log_user_activity(socket, action, user) do
    Activity.log(%{
      activity_type: "user",
      action: action,
      target: user.username,
      actor_username: socket.assigns.current_user.username,
      user_id: user.id
    })
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:users}>
      <.header>
        Users
        <:subtitle>{@user_count} managed key owners</:subtitle>
        <:actions>
          <.button id="new-user" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New user
          </.button>
        </:actions>
      </.header>

      <p :if={@user_count == 0} class="text-sm opacity-60">
        No users yet — create the first one.
      </p>

      <div :if={@user_count > 0} class="overflow-x-auto">
        <.table id="users" rows={@streams.users}>
          <:col :let={{_id, row}} label="Username">
            <span class="font-medium">{row.user.username}</span>
            <p :if={row.user.comment} class="text-xs opacity-60">{row.user.comment}</p>
          </:col>
          <:col :let={{_id, row}} label="Status">
            <span class={["badge badge-sm", (row.user.enabled && "badge-success") || "badge-error"]}>
              {if row.user.enabled, do: "enabled", else: "disabled"}
            </span>
          </:col>
          <:col :let={{_id, row}} label="SSH keys">
            <.link navigate={~p"/keys?user_id=#{row.user.id}"} class="link link-hover">
              {row.key_count}
            </.link>
          </:col>
          <:col :let={{_id, row}} label="Access">
            <.link navigate={~p"/authorizations?user_id=#{row.user.id}"} class="link link-hover">
              {row.authorization_count}
            </.link>
          </:col>
          <:action :let={{_id, row}}>
            <button
              id={"toggle-user-#{row.user.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="toggle_enabled"
              phx-value-id={row.user.id}
              title={if row.user.enabled, do: "Disable user", else: "Enable user"}
            >
              <.icon
                name={if row.user.enabled, do: "hero-pause", else: "hero-play"}
                class="size-4"
              />
            </button>
            <button
              id={"edit-user-#{row.user.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="edit"
              phx-value-id={row.user.id}
              title="Edit user"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              id={"delete-user-#{row.user.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-id={row.user.id}
              data-confirm={"Delete user #{row.user.username}? Their keys and authorizations go with them."}
              title="Delete user"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <.modal :if={@form} id="user-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit user", else: "New user"}</:title>

        <.form for={@form} id="user-form" phx-change="validate" phx-submit="save" class="space-y-2">
          <.input field={@form[:username]} type="text" label="Username" required />
          <.input field={@form[:comment]} type="text" label="Comment" />
          <.input field={@form[:enabled]} type="checkbox" label="Enabled" />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Save changes", else: "Create user"}
            </button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
