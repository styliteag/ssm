defmodule SsmWeb.KeysLive do
  @moduledoc """
  SSH keys page: every stored public key across all users, with stats bar,
  type filter pills, free-text search, owner filter (`?user_id=`),
  paste-to-parse add modal, bulk import modal with a per-line report,
  copy-to-clipboard, view modal, edit, and delete — the React KeysPage.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Authorizations
  alias Ssm.Diffs
  alias Ssm.Users
  alias Ssm.Users.KeyParser
  alias Ssm.Users.UserKey
  alias SsmWeb.Layouts

  @type_filters ~w(all rsa ed25519 ecdsa other)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "SSH Keys",
       form: nil,
       editing: nil,
       viewing: nil,
       paste: "",
       parsed: nil,
       importing: false,
       import_results: nil,
       import_text: "",
       import_user_id: nil,
       search: "",
       type_filter: "all",
       sort: nil,
       view: "list"
     )}
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
    all_keys = Users.list_keys()

    socket
    |> assign(:all_keys, all_keys)
    |> assign(:stats, stats(all_keys))
    |> assign(:hosts_by_user, hosts_per_owner())
    |> refilter()
  end

  defp refilter(socket) do
    %{all_keys: all_keys, filter_user_id: user_id, search: search, type_filter: type_filter} =
      socket.assigns

    scoped =
      case user_id do
        nil -> all_keys
        id -> Enum.filter(all_keys, &(&1.user_id == id))
      end

    searched = apply_search(scoped, search)

    keys =
      searched
      |> apply_type_filter(type_filter)
      |> SsmWeb.TableSort.sort(socket.assigns.sort, key_sorters(socket.assigns.hosts_by_user))

    socket
    |> assign(:type_counts, Enum.frequencies_by(searched, &category_id(&1.key_type)))
    |> assign(:key_count, length(keys))
    |> stream(:keys, keys, reset: true)
  end

  defp key_sorters(hosts_by_user) do
    %{
      "user" => &SsmWeb.TableSort.string(&1.user.username),
      "name" => &SsmWeb.TableSort.string(&1.name),
      "type" => &SsmWeb.TableSort.string(&1.key_type),
      "comment" => &SsmWeb.TableSort.string(&1.extra_comment),
      "access" => &Map.get(hosts_by_user, &1.user_id, 0)
    }
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

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> refilter()}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    sort = SsmWeb.TableSort.toggle(socket.assigns.sort, key)
    {:noreply, socket |> assign(:sort, sort) |> refilter()}
  end

  # Re-stream on toggle so the freshly shown container gets its rows.
  def handle_event("view-mode", %{"view" => view}, socket) when view in ~w(list cards) do
    {:noreply, socket |> assign(:view, view) |> refilter()}
  end

  def handle_event("type-filter", %{"type" => type}, socket) when type in @type_filters do
    {:noreply, socket |> assign(:type_filter, type) |> refilter()}
  end

  def handle_event("new", _params, socket) do
    attrs =
      case socket.assigns.filter_user_id do
        nil -> %{}
        user_id -> %{"user_id" => user_id}
      end

    {:noreply,
     assign(socket,
       form: to_form(Users.change_key(%UserKey{}, attrs)),
       editing: nil,
       paste: "",
       parsed: nil
     )}
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
    {:noreply,
     assign(socket,
       form: nil,
       editing: nil,
       viewing: nil,
       paste: "",
       parsed: nil,
       importing: false,
       import_results: nil
     )}
  end

  def handle_event("validate", %{"user_key" => params}, socket) do
    case socket.assigns.editing do
      nil ->
        {paste, parsed, attrs} = parse_paste(params)
        changeset = %UserKey{} |> Users.change_key(attrs) |> Map.put(:action, :validate)
        {:noreply, assign(socket, form: to_form(changeset), paste: paste, parsed: parsed)}

      key ->
        changeset = key |> Users.change_key(params) |> Map.put(:action, :validate)
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"user_key" => params}, socket) do
    case socket.assigns.editing do
      nil -> save_new(socket, params)
      key -> save_edit(socket, key, params)
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

  def handle_event("import-open", _params, socket) do
    {:noreply,
     assign(socket,
       importing: true,
       import_results: nil,
       import_text: "",
       import_user_id: socket.assigns.filter_user_id
     )}
  end

  def handle_event("import", %{"import" => %{"user_id" => user_id, "keys_text" => text}}, socket) do
    results = import_lines(socket, text, user_id)
    created = Enum.count(results, &(&1.status == :ok))

    socket =
      socket
      |> assign(import_results: results, import_text: text, import_user_id: user_id)
      |> reload_keys()

    socket =
      if created > 0, do: put_flash(socket, :info, "#{created} key(s) imported."), else: socket

    {:noreply, socket}
  end

  ## Save paths

  defp save_new(socket, params) do
    {paste, parsed, attrs} = parse_paste(params)
    parsed = parsed || {:error, "paste a public key line"}
    socket = assign(socket, paste: paste, parsed: parsed)

    with {:ok, _} <- parsed,
         {:ok, key} <- Users.create_key(attrs) do
      log_key_activity(socket, "create", key)

      {:noreply,
       socket
       |> assign(form: nil, editing: nil, paste: "", parsed: nil)
       |> put_flash(:info, "Key #{key_label(key)} created.")
       |> reload_keys()}
    else
      {:error, reason} when is_binary(reason) ->
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(Map.put(changeset, :action, :validate)))
         |> put_flash(:error, create_error(changeset))}
    end
  end

  defp save_edit(socket, key, params) do
    case Users.update_key(key, params) do
      {:ok, updated} ->
        log_key_activity(socket, "update", updated)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Key #{key_label(updated)} updated.")
         |> reload_keys()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Parse the pasted line and build create attrs; an explicit name override
  # wins over the pasted comment.
  defp parse_paste(params) do
    paste = params["public_key"] || ""
    parsed = if String.trim(paste) == "", do: nil, else: KeyParser.parse(paste)

    attrs =
      case parsed do
        {:ok, key} ->
          %{
            "user_id" => params["user_id"],
            "key_type" => key.key_type,
            "key_base64" => key.key_base64,
            "name" => override_or(params["name"], key.name)
          }

        _ ->
          Map.take(params, ["user_id", "name"])
      end

    {paste, parsed, attrs}
  end

  defp override_or(override, comment) when override in [nil, ""], do: comment
  defp override_or(override, _comment), do: override

  defp create_error(changeset) do
    case changeset.errors[:key_base64] do
      {"has already been taken", _} -> "This key already exists."
      {msg, _} -> "Key material #{msg}."
      nil -> "Could not save key — check the form fields."
    end
  end

  ## Import

  defp import_lines(socket, text, user_id) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.trim(line) == "" end)
    |> Enum.map(fn {line, n} -> import_line(socket, line, n, user_id) end)
  end

  defp import_line(socket, line, n, user_id) do
    with {:ok, parsed} <- KeyParser.parse(line),
         {:ok, key} <-
           Users.create_key(%{
             "user_id" => user_id,
             "key_type" => parsed.key_type,
             "key_base64" => parsed.key_base64,
             "name" => parsed.name
           }) do
      log_key_activity(socket, "import", key)
      %{line: n, status: :ok, message: "imported"}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        %{line: n, status: :error, message: import_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        %{line: n, status: :error, message: reason}
    end
  end

  defp import_error(changeset) do
    case changeset.errors[:key_base64] do
      {"has already been taken", _} -> "already exists"
      {msg, _} -> "key material #{msg}"
      nil -> "could not be saved"
    end
  end

  ## Filtering & stats

  defp apply_search(keys, search) do
    case String.trim(search) do
      "" ->
        keys

      needle ->
        needle = String.downcase(needle)

        Enum.filter(keys, fn key ->
          Enum.any?(
            [key.name, key.user.username, key.extra_comment, key.key_type],
            &(is_binary(&1) and String.contains?(String.downcase(&1), needle))
          )
        end)
    end
  end

  defp apply_type_filter(keys, "all"), do: keys

  defp apply_type_filter(keys, filter),
    do: Enum.filter(keys, &(category_id(&1.key_type) == filter))

  defp category_id("ssh-rsa"), do: "rsa"
  defp category_id("ssh-ed25519"), do: "ed25519"
  defp category_id("ecdsa" <> _), do: "ecdsa"
  defp category_id(_), do: "other"

  defp category_label(key_type) do
    case category_id(key_type) do
      "rsa" -> "RSA"
      "ed25519" -> "ED25519"
      "ecdsa" -> "ECDSA"
      "other" -> "Other"
    end
  end

  defp stats(keys) do
    %{
      total: length(keys),
      users_with_keys: keys |> Enum.map(& &1.user_id) |> Enum.uniq() |> length(),
      by_type:
        keys
        |> Enum.frequencies_by(&category_label(&1.key_type))
        |> Enum.sort_by(fn {_label, count} -> -count end)
    }
  end

  defp type_summary([]), do: "—"

  defp type_summary(by_type),
    do: Enum.map_join(by_type, " · ", fn {label, count} -> "#{count} #{label}" end)

  # Distinct hosts each owner can reach through their authorizations.
  # Orphaned grants (host row deleted in the Diesel era) are skipped so the
  # count never includes a host that no longer exists.
  defp hosts_per_owner do
    Authorizations.list_authorizations()
    |> Enum.reject(&is_nil(&1.host))
    |> Enum.group_by(& &1.user_id, & &1.host_id)
    |> Map.new(fn {user_id, host_ids} -> {user_id, host_ids |> Enum.uniq() |> length()} end)
  end

  defp pills(type_counts, active) do
    base = [{"all", "All"}, {"rsa", "RSA"}, {"ed25519", "ED25519"}, {"ecdsa", "ECDSA"}]

    if Map.get(type_counts, "other", 0) > 0 or active == "other" do
      base ++ [{"other", "Other"}]
    else
      base
    end
  end

  defp pill_count(type_counts, "all"), do: type_counts |> Map.values() |> Enum.sum()
  defp pill_count(type_counts, category), do: Map.get(type_counts, category, 0)

  ## Helpers

  defp key_label(%UserKey{name: name}) when is_binary(name) and name != "", do: name
  defp key_label(%UserKey{key_type: type}), do: type

  defp full_key_line(key), do: Diffs.format_key_line(key.key_type, key.key_base64, key.name)

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

  defp paste_feedback({:ok, %{key_type: type, name: nil}}), do: "Detected #{type}, no comment"

  defp paste_feedback({:ok, %{key_type: type, name: comment}}),
    do: "Detected #{type}, comment “#{comment}”"

  defp paste_feedback({:error, reason}), do: "Invalid key: #{reason}"

  defp paste_feedback_class({:ok, _}), do: "text-success"
  defp paste_feedback_class({:error, _}), do: "text-error"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:keys}>
      <.header>
        SSH Keys
        <:subtitle>{@stats.total} stored public keys</:subtitle>
        <:actions>
          <.button id="import-keys" phx-click="import-open">
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import keys
          </.button>
          <.button id="new-key" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> Add key
          </.button>
        </:actions>
      </.header>

      <.stats_bar stats={@stats} />

      <div class="flex flex-wrap items-end gap-4">
        <form id="keys-filter" phx-change="filter" class="w-52">
          <.input
            type="select"
            name="user_id"
            value={@filter_user_id}
            label="Filter by user"
            prompt="All users"
            options={Enum.map(@users, &{&1.username, &1.id})}
          />
        </form>
        <form id="keys-search" phx-change="search" class="w-64">
          <.input
            type="search"
            name="q"
            value={@search}
            label="Search"
            placeholder="Name, user, comment, type"
            phx-debounce="200"
          />
        </form>
      </div>

      <div id="type-pills" class="flex flex-wrap gap-2">
        <button
          :for={{category, label} <- pills(@type_counts, @type_filter)}
          id={"pill-#{category}"}
          type="button"
          class={[
            "btn btn-xs rounded-full",
            if(@type_filter == category, do: "btn-primary", else: "btn-ghost")
          ]}
          phx-click="type-filter"
          phx-value-type={category}
        >
          {label} ({pill_count(@type_counts, category)})
        </button>
      </div>

      <.view_toggle id="keys-view" view={@view} />

      <p :if={@key_count == 0} class="text-sm opacity-60">No keys match the current filters.</p>

      <ul
        :if={@view == "cards" and @key_count > 0}
        id="keys-cards"
        phx-update="stream"
        class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
      >
        <li
          :for={{id, key} <- @streams.keys}
          id={id}
          class="rounded-box bg-base-200 px-4 py-3"
        >
          <div class="flex items-center gap-2">
            <span class="min-w-0 flex-1 truncate font-medium">{key.name || "—"}</span>
            <span class={[
              "badge badge-sm flex-none whitespace-nowrap",
              key_type_badge_class(key.key_type)
            ]}>
              {key.key_type}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap gap-x-3 text-xs opacity-70">
            <.link navigate={~p"/keys?user_id=#{key.user_id}"} class="link link-hover">
              {key.user.username}
            </.link>
            <span title="Distinct hosts the owner has authorizations for">
              {Map.get(@hosts_by_user, key.user_id, 0)} host(s)
            </span>
          </div>
          <p class="mt-1 truncate font-mono text-xs opacity-60">{truncate_key(key.key_base64)}</p>
          <p :if={key.extra_comment} class="mt-1 truncate text-xs opacity-60">
            {key.extra_comment}
          </p>
          <div class="mt-2 flex gap-1">
            <.key_actions key={key} />
          </div>
        </li>
      </ul>

      <div :if={@view == "list" and @key_count > 0} class="overflow-x-auto">
        <.table id="keys" rows={@streams.keys} sort={@sort}>
          <:col :let={{_id, key}} label="User" sort="user">{key.user.username}</:col>
          <:col :let={{_id, key}} label="Name" sort="name">
            <span class="font-medium">{key.name || "—"}</span>
            <p class="font-mono text-xs opacity-60">{truncate_key(key.key_base64)}</p>
          </:col>
          <:col :let={{_id, key}} label="Type" sort="type">
            <span class={["badge badge-sm whitespace-nowrap", key_type_badge_class(key.key_type)]}>
              {key.key_type}
            </span>
          </:col>
          <:col :let={{_id, key}} label="Comment" sort="comment">{key.extra_comment || "—"}</:col>
          <:col :let={{_id, key}} label="Host access via owner" sort="access">
            <span class="tabular-nums" title="Distinct hosts the owner has authorizations for">
              {Map.get(@hosts_by_user, key.user_id, 0)}
            </span>
          </:col>
          <:action :let={{_id, key}}>
            <.key_actions key={key} />
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
        >{full_key_line(@viewing)}</pre>
        <div class="mt-2">
          <.copy_button id="copy-key-view" line={full_key_line(@viewing)} label="Copy key line" />
        </div>
      </.modal>

      <.key_modal
        :if={@form}
        form={@form}
        editing={@editing}
        users={@users}
        paste={@paste}
        parsed={@parsed}
      />

      <.import_modal
        :if={@importing}
        users={@users}
        import_results={@import_results}
        import_text={@import_text}
        import_user_id={@import_user_id}
      />
    </Layouts.app>
    """
  end

  attr :stats, :map, required: true

  defp stats_bar(assigns) do
    ~H"""
    <div id="key-stats" class="stats stats-vertical sm:stats-horizontal w-full bg-base-200 shadow-sm">
      <div class="stat">
        <div class="stat-title">Total keys</div>
        <div class="stat-value text-2xl" id="stat-total">{@stats.total}</div>
      </div>
      <div class="stat">
        <div class="stat-title">Users with keys</div>
        <div class="stat-value text-2xl" id="stat-users">{@stats.users_with_keys}</div>
      </div>
      <div class="stat">
        <div class="stat-title">By type</div>
        <div class="stat-desc text-sm" id="stat-types">{type_summary(@stats.by_type)}</div>
      </div>
    </div>
    """
  end

  attr :key, :any, required: true

  defp key_actions(assigns) do
    ~H"""
    <.copy_button id={"copy-key-#{@key.id}"} line={full_key_line(@key)} />
    <button
      id={"view-key-#{@key.id}"}
      class="btn btn-ghost btn-xs"
      phx-click="view"
      phx-value-id={@key.id}
      title="View full key"
    >
      <.icon name="hero-eye" class="size-4" />
    </button>
    <button
      id={"edit-key-#{@key.id}"}
      class="btn btn-ghost btn-xs"
      phx-click="edit"
      phx-value-id={@key.id}
      title="Edit key"
    >
      <.icon name="hero-pencil-square" class="size-4" />
    </button>
    <button
      id={"delete-key-#{@key.id}"}
      class="btn btn-ghost btn-xs text-error"
      phx-click="delete"
      phx-value-id={@key.id}
      data-confirm={"Delete key #{key_label(@key)} of #{@key.user.username}?"}
      title="Delete key"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  attr :id, :string, required: true
  attr :line, :string, required: true
  attr :label, :string, default: nil

  defp copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="btn btn-ghost btn-xs"
      phx-hook="CopyToClipboard"
      data-copy={@line}
      title="Copy full key line"
    >
      <.icon name="hero-clipboard" class="size-4 [[data-copied]_&]:hidden" />
      <.icon name="hero-check" class="hidden size-4 text-success [[data-copied]_&]:inline-block" />
      <span :if={@label}>{@label}</span>
    </button>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :editing, :any, required: true
  attr :users, :list, required: true
  attr :paste, :string, required: true
  attr :parsed, :any, required: true

  defp key_modal(assigns) do
    ~H"""
    <.modal id="key-modal" on_cancel={JS.push("cancel")}>
      <:title>{if @editing, do: "Edit key", else: "Add key"}</:title>

      <.form for={@form} id="key-form" phx-change="validate" phx-submit="save" class="space-y-2">
        <.input
          field={@form[:user_id]}
          type="select"
          label="User"
          prompt="Select a user"
          options={Enum.map(@users, &{&1.username, &1.id})}
          disabled={@editing != nil}
          required
        />

        <%= if @editing do %>
          <.input
            field={@form[:key_type]}
            type="select"
            label="Key type"
            options={UserKey.key_types()}
            disabled
            required
          />
          <.input field={@form[:key_base64]} type="textarea" label="Key material" disabled required />
        <% else %>
          <.input
            type="textarea"
            id="key-paste"
            name="user_key[public_key]"
            value={@paste}
            label="Public key (paste the full authorized_keys line)"
            placeholder="ssh-ed25519 AAAA… user@host"
            rows="3"
            phx-debounce="300"
            required
          />
          <p :if={@parsed} id="paste-feedback" class={["text-xs", paste_feedback_class(@parsed)]}>
            {paste_feedback(@parsed)}
          </p>
        <% end %>

        <.input
          field={@form[:name]}
          type="text"
          label={if @editing, do: "Name", else: "Name (overrides the pasted comment)"}
        />
        <.input :if={@editing} field={@form[:extra_comment]} type="text" label="Comment" />

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">
            {if @editing, do: "Save changes", else: "Add key"}
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :users, :list, required: true
  attr :import_results, :any, required: true
  attr :import_text, :string, required: true
  attr :import_user_id, :any, required: true

  defp import_modal(assigns) do
    ~H"""
    <.modal id="key-import-modal" on_cancel={JS.push("cancel")}>
      <:title>Import keys</:title>

      <form id="key-import-form" phx-submit="import" class="space-y-2">
        <.input
          type="select"
          name="import[user_id]"
          value={@import_user_id}
          label="Assign all keys to"
          prompt="Select a user"
          options={Enum.map(@users, &{&1.username, &1.id})}
          required
        />
        <.input
          type="textarea"
          name="import[keys_text]"
          value={@import_text}
          label="Public keys — one authorized_keys line each"
          rows="6"
          required
        />

        <div
          :if={@import_results}
          id="import-results"
          class="max-h-40 space-y-1 overflow-auto rounded bg-base-200 p-2 font-mono text-xs"
        >
          <p
            :for={result <- @import_results}
            class={if result.status == :ok, do: "text-success", else: "text-error"}
          >
            Line {result.line}: {result.message}
          </p>
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Close</button>
          <button type="submit" class="btn btn-primary">Import</button>
        </div>
      </form>
    </.modal>
    """
  end
end
