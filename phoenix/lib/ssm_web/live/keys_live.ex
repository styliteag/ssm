defmodule SsmWeb.KeysLive do
  @moduledoc """
  SSH keys page: every stored public key across all users, filterable by
  owner (`?user_id=`), with add/edit modal, a view modal exposing the full
  authorized_keys line, and delete — the React KeysPage core. Import/assign
  bulk tooling is post-parity work.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Diffs
  alias Ssm.Users
  alias Ssm.Users.UserKey
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "SSH Keys", form: nil, editing: nil, viewing: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter_user_id =
      case Integer.parse(params["user_id"] || "") do
        {id, ""} -> id
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_user_id, filter_user_id)
     |> assign(:users, Users.list_users())
     |> reload_keys()}
  end

  defp reload_keys(socket) do
    opts =
      case socket.assigns.filter_user_id do
        nil -> []
        user_id -> [user_id: user_id]
      end

    keys = Users.list_keys(opts)

    socket
    |> assign(:key_count, length(keys))
    |> stream(:keys, keys, reset: true)
  end

  ## Events

  @impl true
  def handle_event("filter", %{"user_id" => value}, socket) do
    to =
      case value do
        "" -> ~p"/keys"
        id -> ~p"/keys?user_id=#{id}"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("new", _params, socket) do
    attrs =
      case socket.assigns.filter_user_id do
        nil -> %{}
        user_id -> %{"user_id" => user_id}
      end

    {:noreply, assign(socket, form: to_form(Users.change_key(%UserKey{}, attrs)), editing: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Users.get_key(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Key not found.")}

      key ->
        {:noreply, assign(socket, form: to_form(Users.change_key(key)), editing: key)}
    end
  end

  def handle_event("view", %{"id" => id}, socket) do
    case Users.get_key(String.to_integer(id)) do
      nil -> {:noreply, put_flash(socket, :error, "Key not found.")}
      key -> {:noreply, assign(socket, :viewing, key)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: nil, viewing: nil)}
  end

  def handle_event("validate", %{"user_key" => params}, socket) do
    changeset =
      (socket.assigns.editing || %UserKey{})
      |> Users.change_key(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user_key" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Users.create_key(params)
        key -> Users.update_key(key, params)
      end

    case result do
      {:ok, key} ->
        action = if socket.assigns.editing, do: "update", else: "create"
        log_key_activity(socket, action, key)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Key #{key_label(key)} #{action}d.")
         |> reload_keys()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %UserKey{} = key <- Users.get_key(String.to_integer(id)),
         {:ok, _} <- Users.delete_key(key) do
      log_key_activity(socket, "delete", key)

      {:noreply,
       socket
       |> put_flash(:info, "Key #{key_label(key)} deleted.")
       |> reload_keys()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found.")}
    end
  end

  ## Helpers

  defp key_label(%UserKey{name: name}) when is_binary(name) and name != "", do: name
  defp key_label(%UserKey{key_type: type}), do: type

  defp truncate_key(base64) when byte_size(base64) <= 32, do: base64
  defp truncate_key(base64), do: String.slice(base64, 0, 32) <> "…"

  defp log_key_activity(socket, action, key) do
    Activity.log(%{
      activity_type: "key",
      action: action,
      target: key_label(key),
      actor_username: socket.assigns.current_user.username,
      user_id: key.user_id,
      details: %{key_type: key.key_type}
    })
  end

  defp key_type_badge_class("ssh-ed25519"), do: "badge-success"
  defp key_type_badge_class("ssh-rsa"), do: "badge-info"
  defp key_type_badge_class("ssh-dss"), do: "badge-warning"

  defp key_type_badge_class(type) do
    cond do
      String.starts_with?(type, "ecdsa") -> "badge-secondary"
      String.starts_with?(type, "sk-") -> "badge-accent"
      true -> "badge-ghost"
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:keys}>
      <.header>
        SSH Keys
        <:subtitle>{@key_count} stored public keys</:subtitle>
        <:actions>
          <.button id="new-key" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> Add key
          </.button>
        </:actions>
      </.header>

      <form id="keys-filter" phx-change="filter" class="max-w-xs">
        <.input
          type="select"
          name="user_id"
          value={@filter_user_id}
          label="Filter by user"
          prompt="All users"
          options={Enum.map(@users, &{&1.username, &1.id})}
        />
      </form>

      <p :if={@key_count == 0} class="text-sm opacity-60">No keys found.</p>

      <div :if={@key_count > 0} class="overflow-x-auto">
        <.table id="keys" rows={@streams.keys}>
          <:col :let={{_id, key}} label="User">{key.user.username}</:col>
          <:col :let={{_id, key}} label="Name">
            <span class="font-medium">{key.name || "—"}</span>
            <p class="font-mono text-xs opacity-60">{truncate_key(key.key_base64)}</p>
          </:col>
          <:col :let={{_id, key}} label="Type">
            <span class={["badge badge-sm", key_type_badge_class(key.key_type)]}>
              {key.key_type}
            </span>
          </:col>
          <:col :let={{_id, key}} label="Comment">{key.extra_comment || "—"}</:col>
          <:action :let={{_id, key}}>
            <button
              id={"view-key-#{key.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="view"
              phx-value-id={key.id}
              title="View full key"
            >
              <.icon name="hero-eye" class="size-4" />
            </button>
            <button
              id={"edit-key-#{key.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="edit"
              phx-value-id={key.id}
              title="Edit key"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              id={"delete-key-#{key.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-id={key.id}
              data-confirm={"Delete key #{key_label(key)} of #{key.user.username}?"}
              title="Delete key"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <.modal :if={@viewing} id="key-view-modal" on_cancel={JS.push("cancel")}>
        <:title>{key_label(@viewing)}</:title>
        <p class="mb-2 text-sm opacity-70">
          Owner: {@viewing.user.username} · Type: {@viewing.key_type}
        </p>
        <pre
          class="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-base-300 p-3 font-mono text-xs"
          id="key-view-line"
        >{Diffs.format_key_line(
          @viewing.key_type,
          @viewing.key_base64,
          @viewing.name
        )}</pre>
      </.modal>

      <.modal :if={@form} id="key-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit key", else: "Add key"}</:title>

        <.form
          for={@form}
          id="key-form"
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
            disabled={@editing != nil}
            required
          />
          <.input
            field={@form[:key_type]}
            type="select"
            label="Key type"
            options={UserKey.key_types()}
            disabled={@editing != nil}
            required
          />
          <.input
            field={@form[:key_base64]}
            type="textarea"
            label="Key material (base64, no type prefix or comment)"
            disabled={@editing != nil}
            required
          />
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:extra_comment]} type="text" label="Comment" />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Save changes", else: "Add key"}
            </button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
