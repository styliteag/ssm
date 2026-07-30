defmodule SsmWeb.UsersLive do
  @moduledoc """
  Users page: managed key owners with per-user key/authorization counts,
  create/edit modal, enable/disable toggle, delete (cascades keys and
  authorizations), row selection with merge + bulk delete, and per-user
  split-keys — the React UsersPage incl. its SplitKeys/MergeUsers/BulkDelete
  modals. Split copies **all** of the source user's authorizations (the React
  modal's default selection) rather than a hand-picked subset.

  Rows are a plain assign, not a stream: selection state must re-render rows,
  and the page loads all users anyway.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Users
  alias Ssm.Users.BulkOps
  alias Ssm.Users.User
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Users")
     |> assign(form: nil, editing: nil)
     |> assign(selected: MapSet.new(), splitting: nil, merging: nil, bulk_deleting: false)
     |> reload_users()}
  end

  defp reload_users(socket) do
    rows =
      Users.list_users_with_counts()
      |> Enum.map(&Map.put(&1, :id, &1.user.id))

    ids = MapSet.new(rows, & &1.id)

    socket
    |> assign(:rows, rows)
    |> assign(:user_count, length(rows))
    |> update(:selected, &MapSet.intersection(&1, ids))
  end

  defp selected_rows(socket), do: selected_rows_from_assigns(socket.assigns)

  defp usernames(socket), do: Enum.map(socket.assigns.rows, & &1.user.username)

  ## Events: create/edit/delete/toggle (unchanged behavior)

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
    {:noreply,
     assign(socket, form: nil, editing: nil, splitting: nil, merging: nil, bulk_deleting: false)}
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

  ## Events: selection

  def handle_event("toggle-select", %{"id" => id}, socket) do
    id = String.to_integer(id)

    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("toggle-select-all", _params, socket) do
    all = MapSet.new(socket.assigns.rows, & &1.id)

    selected =
      if MapSet.equal?(socket.assigns.selected, all), do: MapSet.new(), else: all

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  ## Events: split keys

  def handle_event("split-open", %{"id" => id}, socket) do
    case Users.get_user(String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:noreply,
         assign(socket, :splitting, %{
           user: user,
           keys: Users.list_keys(user_id: user.id),
           username: BulkOps.suggest_split_username(user.username, usernames(socket)),
           selected_keys: MapSet.new()
         })}
    end
  end

  def handle_event("split-toggle-key", %{"id" => id}, socket) do
    id = String.to_integer(id)
    splitting = socket.assigns.splitting

    selected_keys =
      if MapSet.member?(splitting.selected_keys, id) do
        MapSet.delete(splitting.selected_keys, id)
      else
        MapSet.put(splitting.selected_keys, id)
      end

    {:noreply, assign(socket, :splitting, %{splitting | selected_keys: selected_keys})}
  end

  def handle_event("split-change", %{"split" => %{"username" => username}}, socket) do
    {:noreply, assign(socket, :splitting, %{socket.assigns.splitting | username: username})}
  end

  def handle_event("split-save", _params, socket) do
    %{user: user, username: username, selected_keys: selected_keys} = socket.assigns.splitting

    case BulkOps.split_user(user, String.trim(username), MapSet.to_list(selected_keys)) do
      {:ok, result} ->
        log_split(socket, user, result)

        {:noreply,
         socket
         |> assign(:splitting, nil)
         |> put_flash(:info, split_summary(result))
         |> reload_users()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, bulk_error(reason))}
    end
  end

  ## Events: merge

  def handle_event("merge-open", _params, socket) do
    case selected_rows(socket) do
      rows when length(rows) < 2 ->
        {:noreply, put_flash(socket, :error, "Select at least two users to merge.")}

      rows ->
        first = hd(rows).user

        {:noreply,
         assign(socket, :merging, %{
           rows: rows,
           mode: "existing",
           target_id: first.id,
           username: BulkOps.suggest_merge_username(first.username, usernames(socket)),
           enabled: true,
           comment: ""
         })}
    end
  end

  def handle_event("merge-change", %{"merge" => params}, socket) do
    merging = %{
      socket.assigns.merging
      | mode: params["mode"] || "existing",
        target_id: parse_id(params["target_id"]) || socket.assigns.merging.target_id,
        username: params["username"] || socket.assigns.merging.username,
        enabled: params["enabled"] in [nil, "true"],
        comment: params["comment"] || ""
    }

    {:noreply, assign(socket, :merging, merging)}
  end

  def handle_event("merge-save", _params, socket) do
    merging = socket.assigns.merging
    users = Enum.map(merging.rows, & &1.user)

    case BulkOps.merge_users(users, merge_target(merging, users)) do
      {:ok, result} ->
        log_merge(socket, result)

        {:noreply,
         socket
         |> assign(merging: nil, selected: MapSet.new())
         |> put_flash(:info, merge_summary(result))
         |> reload_users()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, bulk_error(reason))}
    end
  end

  ## Events: bulk delete

  def handle_event("bulk-delete-open", _params, socket) do
    case selected_rows(socket) do
      [] -> {:noreply, put_flash(socket, :error, "Select at least one user to delete.")}
      _rows -> {:noreply, assign(socket, :bulk_deleting, true)}
    end
  end

  def handle_event("bulk-delete-confirm", _params, socket) do
    result =
      socket
      |> selected_rows()
      |> Enum.map(& &1.user)
      |> BulkOps.bulk_delete()

    Enum.each(result.deleted, &log_user_activity(socket, "delete", &1))

    socket =
      socket
      |> assign(bulk_deleting: false, selected: MapSet.new())
      |> put_flash(:info, "#{length(result.deleted)} user(s) deleted.")
      |> reload_users()

    socket =
      case result.failed do
        [] -> socket
        failed -> put_flash(socket, :error, "#{length(failed)} user(s) could not be deleted.")
      end

    {:noreply, socket}
  end

  defp selected_rows_from_assigns(%{rows: rows, selected: selected}) do
    Enum.filter(rows, &MapSet.member?(selected, &1.id))
  end

  ## Helpers

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp merge_target(%{mode: "existing", target_id: target_id}, users) do
    Enum.find(users, &(&1.id == target_id)) || hd(users)
  end

  defp merge_target(%{mode: "new"} = merging, _users) do
    %{
      username: String.trim(merging.username),
      enabled: merging.enabled,
      comment: presence(merging.comment)
    }
  end

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp split_summary(result) do
    "Created #{result.new_user.username} with #{result.moved_keys} key(s) " <>
      "and #{result.copied_authorizations} copied authorization(s)."
  end

  defp merge_summary(result) do
    "Merged #{length(result.deleted_users)} user(s) into #{result.target.username}: " <>
      "#{result.moved_keys} key(s) moved, #{result.copied_authorizations} authorization(s) " <>
      "copied, #{result.skipped_authorizations} duplicate(s) skipped."
  end

  defp bulk_error(:no_keys_selected), do: "Select at least one key to move."
  defp bulk_error(:keys_not_owned), do: "Selected keys no longer belong to this user."
  defp bulk_error(:must_keep_one_key), do: "The original user must keep at least one key."
  defp bulk_error(:nothing_to_merge), do: "Select at least one other user to merge."

  defp bulk_error({:user_not_found, username}),
    do: "User #{username} disappeared before the merge finished."

  defp bulk_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:username] do
      {"has already been taken", _} -> "That username is already taken."
      {message, _} -> "Username #{message}."
      nil -> "Could not save — check the form fields."
    end
  end

  defp log_split(socket, user, result) do
    Activity.log(%{
      activity_type: "user",
      action: "split",
      target: result.new_user.username,
      actor_username: socket.assigns.current_user.username,
      user_id: result.new_user.id,
      details: %{
        from: user.username,
        moved_keys: result.moved_keys,
        copied_authorizations: result.copied_authorizations
      }
    })
  end

  defp log_merge(socket, result) do
    Activity.log(%{
      activity_type: "user",
      action: "merge",
      target: result.target.username,
      actor_username: socket.assigns.current_user.username,
      user_id: result.target.id,
      details: %{
        merged_users: Enum.join(result.deleted_users, ", "),
        moved_keys: result.moved_keys,
        copied_authorizations: result.copied_authorizations,
        skipped_authorizations: result.skipped_authorizations
      }
    })
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

      <div
        :if={MapSet.size(@selected) > 0}
        id="bulk-toolbar"
        class="flex flex-wrap items-center gap-2 rounded-box bg-base-200 px-3 py-2"
      >
        <span class="text-sm">{MapSet.size(@selected)} selected</span>
        <button
          id="bulk-merge"
          class="btn btn-sm"
          phx-click="merge-open"
          disabled={MapSet.size(@selected) < 2}
        >
          <.icon name="hero-arrows-pointing-in" class="size-4" /> Merge
        </button>
        <button id="bulk-delete" class="btn btn-sm btn-error" phx-click="bulk-delete-open">
          <.icon name="hero-trash" class="size-4" /> Delete ({MapSet.size(@selected)})
        </button>
        <button class="btn btn-ghost btn-sm" phx-click="clear-selection">Clear</button>
      </div>

      <div :if={@user_count > 0} class="overflow-x-auto">
        <.table id="users" rows={@rows} row_id={&"users-#{&1.id}"} row_item={&Function.identity/1}>
          <:col :let={row} label="">
            <input
              type="checkbox"
              id={"select-user-#{row.id}"}
              class="checkbox checkbox-sm align-middle"
              checked={MapSet.member?(@selected, row.id)}
              phx-click="toggle-select"
              phx-value-id={row.id}
            />
          </:col>
          <:col :let={row} label="Username">
            <span class="font-medium">{row.user.username}</span>
            <p :if={row.user.comment} class="text-xs opacity-60">{row.user.comment}</p>
          </:col>
          <:col :let={row} label="Status">
            <span class={["badge badge-sm", (row.user.enabled && "badge-success") || "badge-error"]}>
              {if row.user.enabled, do: "enabled", else: "disabled"}
            </span>
          </:col>
          <:col :let={row} label="SSH keys">
            <.link navigate={~p"/keys?user_id=#{row.user.id}"} class="link link-hover">
              {row.key_count}
            </.link>
          </:col>
          <:col :let={row} label="Access">
            <.link navigate={~p"/authorizations?user_id=#{row.user.id}"} class="link link-hover">
              {row.authorization_count}
            </.link>
          </:col>
          <:action :let={row}>
            <button
              :if={row.key_count > 1}
              id={"split-user-#{row.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="split-open"
              phx-value-id={row.id}
              title="Split keys to a new user"
            >
              <.icon name="hero-scissors" class="size-4" />
            </button>
            <button
              id={"toggle-user-#{row.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="toggle_enabled"
              phx-value-id={row.id}
              title={if row.user.enabled, do: "Disable user", else: "Enable user"}
            >
              <.icon name={if row.user.enabled, do: "hero-pause", else: "hero-play"} class="size-4" />
            </button>
            <button
              id={"edit-user-#{row.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="edit"
              phx-value-id={row.id}
              title="Edit user"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              id={"delete-user-#{row.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-id={row.id}
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

      <.split_modal :if={@splitting} splitting={@splitting} />
      <.merge_modal :if={@merging} merging={@merging} />
      <.bulk_delete_modal :if={@bulk_deleting} rows={selected_rows_from_assigns(assigns)} />
    </Layouts.app>
    """
  end

  attr :splitting, :map, required: true

  defp split_modal(assigns) do
    ~H"""
    <.modal id="split-modal" on_cancel={JS.push("cancel")}>
      <:title>Split keys from {@splitting.user.username}</:title>

      <p class="mb-2 text-sm opacity-70">
        Moves the selected keys to a new user and copies all of {@splitting.user.username}'s authorizations to it. The original user keeps
        the unselected keys.
      </p>

      <form id="split-form" phx-change="split-change" phx-submit="split-save" class="space-y-2">
        <.input
          type="text"
          name="split[username]"
          value={@splitting.username}
          label="New username"
          required
        />

        <fieldset class="fieldset">
          <span class="label mb-1">
            Keys to move ({MapSet.size(@splitting.selected_keys)} of {length(@splitting.keys)} selected)
          </span>
          <label
            :for={key <- @splitting.keys}
            class="flex cursor-pointer items-center gap-2 rounded px-1 py-0.5 hover:bg-base-200"
          >
            <input
              type="checkbox"
              id={"split-key-#{key.id}"}
              class="checkbox checkbox-sm"
              checked={MapSet.member?(@splitting.selected_keys, key.id)}
              phx-click="split-toggle-key"
              phx-value-id={key.id}
            />
            <span class="text-sm">{key.name || key.key_type}</span>
            <span class="badge badge-ghost badge-xs font-mono">{key.key_type}</span>
          </label>
        </fieldset>

        <p
          :if={MapSet.size(@splitting.selected_keys) >= length(@splitting.keys)}
          class="text-xs text-warning"
        >
          The original user must keep at least one key.
        </p>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">Split</button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :merging, :map, required: true

  defp merge_modal(assigns) do
    ~H"""
    <.modal id="merge-modal" on_cancel={JS.push("cancel")}>
      <:title>Merge {length(@merging.rows)} users</:title>

      <p class="mb-2 text-sm opacity-70">
        All keys move to the target; authorizations are copied (duplicates skipped);
        the other users are deleted.
      </p>

      <form id="merge-form" phx-change="merge-change" phx-submit="merge-save" class="space-y-2">
        <div class="flex gap-4">
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="radio"
              name="merge[mode]"
              value="existing"
              class="radio radio-sm"
              checked={@merging.mode == "existing"}
            /> Into an existing user
          </label>
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="radio"
              name="merge[mode]"
              value="new"
              class="radio radio-sm"
              checked={@merging.mode == "new"}
            /> Into a new user
          </label>
        </div>

        <.input
          :if={@merging.mode == "existing"}
          type="select"
          name="merge[target_id]"
          value={@merging.target_id}
          label="Target user"
          options={Enum.map(@merging.rows, &{&1.user.username, &1.user.id})}
        />

        <%= if @merging.mode == "new" do %>
          <.input
            type="text"
            name="merge[username]"
            value={@merging.username}
            label="New username"
            required
          />
          <.input type="text" name="merge[comment]" value={@merging.comment} label="Comment" />
          <.input type="checkbox" name="merge[enabled]" checked={@merging.enabled} label="Enabled" />
        <% end %>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">Merge</button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :rows, :list, required: true

  defp bulk_delete_modal(assigns) do
    assigns =
      assign(assigns,
        key_total: assigns.rows |> Enum.map(& &1.key_count) |> Enum.sum(),
        auth_total: assigns.rows |> Enum.map(& &1.authorization_count) |> Enum.sum()
      )

    ~H"""
    <.modal id="bulk-delete-modal" on_cancel={JS.push("cancel")}>
      <:title>Delete {length(@rows)} users</:title>

      <p class="mb-2 text-sm">
        This permanently removes <strong>{length(@rows)} user(s)</strong>, <strong>{@key_total} SSH key(s)</strong>, and <strong>{@auth_total} authorization(s)</strong>.
      </p>

      <ul class="mb-2 max-h-40 list-inside list-disc overflow-auto text-sm opacity-80">
        <li :for={row <- @rows}>
          {row.user.username} — {row.key_count} key(s), {row.authorization_count} authorization(s)
        </li>
      </ul>

      <div class="modal-action">
        <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
        <button id="bulk-delete-confirm" class="btn btn-error" phx-click="bulk-delete-confirm">
          Delete all
        </button>
      </div>
    </.modal>
    """
  end
end
