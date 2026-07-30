defmodule SsmWeb.AuthorizationsLive do
  @moduledoc """
  Authorizations page in three views (`?view=list|matrix|stats`), the React
  AuthorizationsPage:

    * list — grants filterable by user or host (`?user_id=` / `?host_id=`),
      add/edit modal, delete, bulk grant (users × hosts cross product,
      existing grants skipped), CSV export honoring the filters
    * matrix — users × hosts grid per login account (`?login=`, sorted by
      usage, smart default root-or-most-used, `all` is view-only counts),
      cell click toggles the grant, `?authorized=1` hides unauthorized users
    * stats — totals plus hosts-by-user-access and users-by-host-access
      rankings
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
    {:ok,
     assign(socket,
       page_title: "Authorizations",
       form: nil,
       editing: nil,
       bulk: nil,
       matrix_user_search: "",
       matrix_host_search: "",
       auth_sort: nil,
       auth_search: ""
     )}
  end

  @view_modes ~w(list matrix stats)

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] in @view_modes, do: params["view"], else: "list"

    {:noreply,
     socket
     |> assign(:view, view)
     |> assign(:filter_user_id, parse_id(params["user_id"]))
     |> assign(:filter_host_id, parse_id(params["host_id"]))
     |> assign(:users, Users.list_users())
     |> assign(:hosts, Hosts.list_hosts())
     |> assign(:show_authorized_only, params["authorized"] == "1")
     |> assign(:matrix_login_param, params["login"])
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

    authorizations =
      opts
      |> Authorizations.list_authorizations()
      |> search_authorizations(socket.assigns.auth_search)
      |> SsmWeb.TableSort.sort(socket.assigns.auth_sort, auth_sorters())

    socket
    |> assign(:authorization_count, length(authorizations))
    |> stream(:authorizations, authorizations, reset: true)
    |> reload_matrix()
  end

  defp search_authorizations(authorizations, search) do
    case search |> String.trim() |> String.downcase() do
      "" ->
        authorizations

      needle ->
        Enum.filter(authorizations, fn auth ->
          [user_label(auth), host_label(auth), auth.login, auth.options, auth.comment]
          |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
        end)
    end
  end

  defp auth_sorters do
    %{
      "user" => &SsmWeb.TableSort.string(user_label(&1)),
      "host" => &SsmWeb.TableSort.string(host_label(&1)),
      "login" => &SsmWeb.TableSort.string(&1.login),
      "options" => &SsmWeb.TableSort.string(&1.options),
      "comment" => &SsmWeb.TableSort.string(&1.comment)
    }
  end

  defp reload_matrix(socket) do
    all = Authorizations.list_authorizations()
    accounts = login_accounts(all)
    login = pick_login(socket.assigns.matrix_login_param, accounts)

    socket
    |> assign(:all_authorizations, all)
    |> assign(:login_accounts, accounts)
    |> assign(:matrix_login, login)
    |> assign(:matrix, build_matrix(socket.assigns, all, login))
  end

  # Distinct logins with usage counts, most-used first.
  defp login_accounts(authorizations) do
    authorizations
    |> Enum.frequencies_by(& &1.login)
    |> Enum.sort_by(fn {_login, count} -> -count end)
  end

  # URL choice wins if still valid; else root; else the most-used login.
  defp pick_login(param, accounts) do
    logins = Enum.map(accounts, fn {login, _count} -> login end)

    cond do
      param == "all" or param in logins -> param
      "root" in logins -> "root"
      logins != [] -> hd(logins)
      true -> "all"
    end
  end

  defp build_matrix(assigns, authorizations, "all") do
    counts = Enum.frequencies_by(authorizations, &{&1.user_id, &1.host_id})
    authorized_users = MapSet.new(authorizations, & &1.user_id)

    %{
      mode: :all,
      cells: counts,
      hosts: matrix_hosts(assigns, assigns.hosts),
      users: matrix_users(assigns, authorized_users)
    }
  end

  defp build_matrix(assigns, authorizations, login) do
    scoped = Enum.filter(authorizations, &(&1.login == login))
    pairs = MapSet.new(scoped, &{&1.user_id, &1.host_id})
    host_ids = MapSet.new(scoped, & &1.host_id)
    authorized_users = MapSet.new(scoped, & &1.user_id)

    %{
      mode: :login,
      cells: pairs,
      hosts: matrix_hosts(assigns, Enum.filter(assigns.hosts, &MapSet.member?(host_ids, &1.id))),
      users: matrix_users(assigns, authorized_users)
    }
  end

  defp matrix_hosts(assigns, hosts) do
    hosts
    |> filter_by_name(assigns.matrix_host_search, &"#{&1.name} #{&1.address}")
    |> Enum.sort_by(& &1.name)
  end

  defp matrix_users(assigns, authorized_users) do
    assigns.users
    |> Enum.filter(fn user ->
      not assigns.show_authorized_only or MapSet.member?(authorized_users, user.id)
    end)
    |> filter_by_name(assigns.matrix_user_search, & &1.username)
    |> Enum.sort_by(& &1.username)
  end

  defp rebuild_matrix(socket) do
    assign(
      socket,
      :matrix,
      build_matrix(socket.assigns, socket.assigns.all_authorizations, socket.assigns.matrix_login)
    )
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
    {:noreply, assign(socket, form: nil, editing: nil, bulk: nil)}
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

  ## Events: matrix

  def handle_event("matrix-login", %{"login" => login}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/authorizations?#{matrix_query(socket.assigns, login: login)}")}
  end

  def handle_event("matrix-authorized", _params, socket) do
    query = matrix_query(socket.assigns, authorized: not socket.assigns.show_authorized_only)
    {:noreply, push_patch(socket, to: ~p"/authorizations?#{query}")}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    sort = SsmWeb.TableSort.toggle(socket.assigns.auth_sort, key)
    {:noreply, socket |> assign(:auth_sort, sort) |> reload_authorizations()}
  end

  def handle_event("list-search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:auth_search, q) |> reload_authorizations()}
  end

  def handle_event("matrix-user-search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:matrix_user_search, q) |> rebuild_matrix()}
  end

  def handle_event("matrix-host-search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:matrix_host_search, q) |> rebuild_matrix()}
  end

  def handle_event("matrix-toggle", %{"user-id" => user_id, "host-id" => host_id}, socket) do
    case socket.assigns.matrix_login do
      "all" -> {:noreply, socket}
      login -> toggle_grant(socket, String.to_integer(user_id), String.to_integer(host_id), login)
    end
  end

  ## Events: bulk grant

  def handle_event("bulk-open", _params, socket) do
    {:noreply,
     socket
     |> assign(:bulk, %{
       user_ids: MapSet.new(),
       host_ids: MapSet.new(),
       login: "",
       options: "",
       user_search: "",
       host_search: "",
       new_count: 0,
       existing_count: 0
     })}
  end

  def handle_event("bulk-user-search", %{"q" => q}, socket) do
    {:noreply, update_bulk(socket, &%{&1 | user_search: q})}
  end

  def handle_event("bulk-host-search", %{"q" => q}, socket) do
    {:noreply, update_bulk(socket, &%{&1 | host_search: q})}
  end

  def handle_event("bulk-toggle-user", %{"id" => id}, socket) do
    {:noreply, update_bulk(socket, &%{&1 | user_ids: toggle(&1.user_ids, id)})}
  end

  def handle_event("bulk-toggle-host", %{"id" => id}, socket) do
    {:noreply, update_bulk(socket, &%{&1 | host_ids: toggle(&1.host_ids, id)})}
  end

  def handle_event("bulk-all-users", _params, socket) do
    enabled = for user <- socket.assigns.users, user.enabled, do: user.id
    {:noreply, update_bulk(socket, &%{&1 | user_ids: MapSet.new(enabled)})}
  end

  def handle_event("bulk-no-users", _params, socket) do
    {:noreply, update_bulk(socket, &%{&1 | user_ids: MapSet.new()})}
  end

  def handle_event("bulk-all-hosts", _params, socket) do
    {:noreply,
     update_bulk(socket, &%{&1 | host_ids: MapSet.new(socket.assigns.hosts, fn h -> h.id end)})}
  end

  def handle_event("bulk-no-hosts", _params, socket) do
    {:noreply, update_bulk(socket, &%{&1 | host_ids: MapSet.new()})}
  end

  def handle_event("bulk-change", %{"bulk" => params}, socket) do
    {:noreply,
     update_bulk(
       socket,
       &%{&1 | login: params["login"] || "", options: params["options"] || ""}
     )}
  end

  def handle_event("bulk-save", _params, socket) do
    %{user_ids: user_ids, host_ids: host_ids, login: login, options: options} =
      socket.assigns.bulk

    login = String.trim(login)

    cond do
      MapSet.size(user_ids) == 0 or MapSet.size(host_ids) == 0 ->
        {:noreply, put_flash(socket, :error, "Select at least one user and one host.")}

      login == "" ->
        {:noreply, put_flash(socket, :error, "The remote login must not be empty.")}

      true ->
        bulk_save(socket, MapSet.to_list(user_ids), MapSet.to_list(host_ids), login, options)
    end
  end

  ## Matrix helpers

  defp toggle_grant(socket, user_id, host_id, login) do
    case Authorizations.get_by_grant(user_id, host_id, login) do
      nil -> grant_cell(socket, user_id, host_id, login)
      auth -> revoke_cell(socket, auth)
    end
  end

  defp grant_cell(socket, user_id, host_id, login) do
    case Authorizations.create_authorization(%{user_id: user_id, host_id: host_id, login: login}) do
      {:ok, auth} ->
        log_auth_activity(socket, "create", auth)
        {:noreply, reload_authorizations(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create the authorization.")}
    end
  end

  defp revoke_cell(socket, auth) do
    case Authorizations.delete_authorization(auth) do
      {:ok, _} ->
        log_auth_activity(socket, "delete", auth)
        {:noreply, reload_authorizations(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not revoke the authorization.")}
    end
  end

  defp matrix_query(assigns, overrides) do
    login = Keyword.get(overrides, :login, assigns.matrix_login)
    authorized = Keyword.get(overrides, :authorized, assigns.show_authorized_only)

    [view: "matrix", login: login] ++ if authorized, do: [authorized: "1"], else: []
  end

  ## Bulk grant helpers

  defp bulk_save(socket, user_ids, host_ids, login, options) do
    case Authorizations.bulk_grant(user_ids, host_ids, login, presence(options)) do
      {:ok, %{created: created, skipped: skipped}} ->
        log_bulk_grant(socket, login, user_ids, host_ids, created, skipped)

        {:noreply,
         socket
         |> assign(:bulk, nil)
         |> put_flash(
           :info,
           "#{length(created)} authorization(s) created, #{skipped} already existed."
         )
         |> reload_authorizations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, bulk_grant_error(changeset))}
    end
  end

  defp update_bulk(socket, fun) do
    bulk = fun.(socket.assigns.bulk)

    {new_count, existing_count} =
      preview_counts(bulk.user_ids, bulk.host_ids, String.trim(bulk.login))

    assign(socket, :bulk, %{bulk | new_count: new_count, existing_count: existing_count})
  end

  defp preview_counts(user_ids, host_ids, login) do
    total = MapSet.size(user_ids) * MapSet.size(host_ids)

    if total == 0 or login == "" do
      {total, 0}
    else
      existing =
        Authorizations.existing_grant_pairs(
          MapSet.to_list(user_ids),
          MapSet.to_list(host_ids),
          login
        )

      {total - MapSet.size(existing), MapSet.size(existing)}
    end
  end

  defp toggle(set, id) do
    id = String.to_integer(id)
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp bulk_grant_error(changeset) do
    case changeset.errors[:login] do
      {message, _} -> "Login #{message}."
      nil -> "Could not create the authorizations — check the form fields."
    end
  end

  defp log_bulk_grant(socket, login, user_ids, host_ids, created, skipped) do
    Activity.log(%{
      activity_type: "auth",
      action: "bulk_grant",
      target: "#{login} (#{length(created)} grants)",
      actor_username: socket.assigns.current_user.username,
      details: %{
        login: login,
        users: length(user_ids),
        hosts: length(host_ids),
        created: length(created),
        skipped: skipped
      }
    })
  end

  ## Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Legacy Diesel-era DBs hold orphaned grants (user/host deleted while FK
  # enforcement was off), so a preloaded association can come back nil.
  defp user_label(%{user: %{username: username}}), do: username
  defp user_label(auth), do: "missing user ##{auth.user_id}"

  defp host_label(%{host: %{name: name}}), do: name
  defp host_label(auth), do: "missing host ##{auth.host_id}"

  defp log_auth_activity(socket, action, auth) do
    auth = Ssm.Repo.preload(auth, [:user, :host])
    target = "#{user_label(auth)}@#{host_label(auth)}:#{auth.login}"

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
          <a
            id="export-csv"
            class="btn"
            href={~p"/authorizations/export?#{export_query(assigns)}"}
            title="Download the filtered list as CSV"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
          </a>
          <.button id="bulk-grant" phx-click="bulk-open">
            <.icon name="hero-user-group" class="size-4" /> Bulk grant
          </.button>
          <.button id="new-authorization" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New authorization
          </.button>
        </:actions>
      </.header>

      <div id="view-switcher" class="join">
        <.link
          patch={~p"/authorizations"}
          class={["btn btn-sm join-item", @view == "list" && "btn-primary"]}
        >
          List
        </.link>
        <.link
          patch={~p"/authorizations?#{matrix_query(assigns, [])}"}
          class={["btn btn-sm join-item", @view == "matrix" && "btn-primary"]}
        >
          Matrix
        </.link>
        <.link
          patch={~p"/authorizations?view=stats"}
          class={["btn btn-sm join-item", @view == "stats" && "btn-primary"]}
        >
          Stats
        </.link>
      </div>

      <.matrix_view
        :if={@view == "matrix"}
        matrix={@matrix}
        matrix_login={@matrix_login}
        login_accounts={@login_accounts}
        show_authorized_only={@show_authorized_only}
        matrix_user_search={@matrix_user_search}
        matrix_host_search={@matrix_host_search}
      />

      <.stats_view
        :if={@view == "stats"}
        all_authorizations={@all_authorizations}
        users={@users}
        hosts={@hosts}
      />

      <.list_stats
        :if={@view == "list"}
        all_authorizations={@all_authorizations}
      />

      <div :if={@view == "list"} class="flex flex-wrap items-end gap-3">
        <form id="authorizations-filter" phx-change="filter" class="flex max-w-xl flex-1 gap-3">
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
        <form id="authorizations-search" phx-change="list-search" class="w-72">
          <.input
            type="search"
            name="q"
            value={@auth_search}
            label="Search"
            placeholder="User, host, login, options, comment"
            phx-debounce="200"
          />
        </form>
      </div>

      <p :if={@view == "list" and @authorization_count == 0} class="text-sm opacity-60">
        No authorizations found.
      </p>

      <div :if={@view == "list" and @authorization_count > 0} class="overflow-x-auto">
        <.table id="authorizations" rows={@streams.authorizations} sort={@auth_sort}>
          <:col :let={{_id, auth}} label="User" sort="user">
            <span :if={is_nil(auth.user)} class="text-error italic">{user_label(auth)}</span>
            <span :if={auth.user} class="inline-flex items-center gap-1">
              <.link
                patch={~p"/authorizations?user_id=#{auth.user_id}"}
                class="link link-hover"
                title={"Filter this list by #{user_label(auth)}"}
              >
                {user_label(auth)}
              </.link>
              <.link
                navigate={~p"/keys?user_id=#{auth.user_id}"}
                class="opacity-40 hover:opacity-100"
                title={"Keys of #{user_label(auth)}"}
              >
                <.icon name="hero-key" class="size-3.5" />
              </.link>
            </span>
          </:col>
          <:col :let={{_id, auth}} label="Host" sort="host">
            <span :if={is_nil(auth.host)} class="text-error italic">{host_label(auth)}</span>
            <span :if={auth.host} class="inline-flex items-center gap-1">
              <.link
                patch={~p"/authorizations?host_id=#{auth.host_id}"}
                class="link link-hover"
                title={"Filter this list by #{host_label(auth)}"}
              >
                {host_label(auth)}
              </.link>
              <.link
                navigate={~p"/diff?host_id=#{auth.host_id}"}
                class="opacity-40 hover:opacity-100"
                title={"Open #{host_label(auth)} in the diff viewer"}
              >
                <.icon name="hero-arrows-right-left" class="size-3.5" />
              </.link>
            </span>
          </:col>
          <:col :let={{_id, auth}} label="Login" sort="login">
            <span class="font-mono text-sm">{auth.login}</span>
          </:col>
          <:col :let={{_id, auth}} label="Options" sort="options">
            <span class="font-mono text-xs">{auth.options || "—"}</span>
          </:col>
          <:col :let={{_id, auth}} label="Comment" sort="comment">{auth.comment || "—"}</:col>
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
              data-confirm={"Revoke access for #{user_label(auth)} on #{host_label(auth)} (login #{auth.login})?"}
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

      <.bulk_modal :if={@bulk} bulk={@bulk} users={@users} hosts={@hosts} />
    </Layouts.app>
    """
  end

  defp export_query(assigns) do
    [user_id: assigns.filter_user_id, host_id: assigns.filter_host_id]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  attr :matrix, :map, required: true
  attr :matrix_login, :string, required: true
  attr :login_accounts, :list, required: true
  attr :show_authorized_only, :boolean, required: true
  attr :matrix_user_search, :string, required: true
  attr :matrix_host_search, :string, required: true

  defp matrix_view(assigns) do
    ~H"""
    <div id="matrix" class="space-y-3">
      <div class="flex flex-wrap items-end gap-3">
        <form id="matrix-user-search-form" phx-change="matrix-user-search" class="w-56">
          <label class="fieldset mb-2">
            <span class="label mb-1">Search users</span>
            <input
              type="search"
              name="q"
              value={@matrix_user_search}
              placeholder="Username…"
              class="input input-sm w-full"
              phx-debounce="150"
              autocomplete="off"
            />
          </label>
        </form>
        <form id="matrix-host-search-form" phx-change="matrix-host-search" class="w-56">
          <label class="fieldset mb-2">
            <span class="label mb-1">Search hosts</span>
            <input
              type="search"
              name="q"
              value={@matrix_host_search}
              placeholder="Name or address…"
              class="input input-sm w-full"
              phx-debounce="150"
              autocomplete="off"
            />
          </label>
        </form>
        <form id="matrix-login-form" phx-change="matrix-login" class="w-56">
          <.input
            type="select"
            name="login"
            value={@matrix_login}
            label="Login account"
            options={
              [{"all (view only)", "all"}] ++
                Enum.map(@login_accounts, fn {login, count} -> {"#{login} (#{count})", login} end)
            }
          />
        </form>
        <button
          id="matrix-authorized-toggle"
          type="button"
          class={["btn btn-sm mb-2", @show_authorized_only && "btn-primary"]}
          phx-click="matrix-authorized"
        >
          <.icon name="hero-eye" class="size-4" /> Show authorized only
        </button>
      </div>

      <p :if={@matrix.hosts == []} class="text-sm opacity-60">
        No hosts hold a grant for this login yet.
      </p>

      <div :if={@matrix.hosts != []} class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-xs w-auto border-collapse">
          <thead>
            <tr>
              <th class="sticky left-0 z-10 bg-base-200 align-bottom">Users / Hosts</th>
              <th :for={host <- @matrix.hosts} class="bg-base-200 px-1 pb-2 align-bottom">
                <.link
                  navigate={~p"/diff?host_id=#{host.id}"}
                  class="link link-hover inline-block max-h-36 truncate whitespace-nowrap [writing-mode:vertical-rl] rotate-180"
                  title={"#{host.name} (#{host.address}) — open in the diff viewer"}
                >
                  {host.name}
                </.link>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @matrix.users} id={"matrix-row-#{user.id}"} class="hover:bg-base-200">
              <th class="sticky left-0 z-10 max-w-56 bg-base-100 font-medium">
                <.link
                  patch={~p"/authorizations?user_id=#{user.id}"}
                  class="link link-hover block truncate"
                  title={"#{user.username}#{if(user.enabled, do: "", else: " (disabled)")} — list this user's grants"}
                >
                  {user.username}
                </.link>
              </th>
              <td
                :for={host <- @matrix.hosts}
                class="border border-base-300/50 p-0.5 text-center"
              >
                <.matrix_cell
                  matrix={@matrix}
                  matrix_login={@matrix_login}
                  user={user}
                  host={host}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@matrix_login == "all"} class="text-xs opacity-60">
        Counts show grants across all login accounts — pick a login to edit.
      </p>
    </div>
    """
  end

  attr :matrix, :map, required: true
  attr :matrix_login, :string, required: true
  attr :user, :any, required: true
  attr :host, :any, required: true

  defp matrix_cell(%{matrix: %{mode: :all}} = assigns) do
    assigns =
      assign(
        assigns,
        :count,
        Map.get(assigns.matrix.cells, {assigns.user.id, assigns.host.id}, 0)
      )

    ~H"""
    <span
      id={"matrix-cell-#{@user.id}-#{@host.id}"}
      class={["badge badge-sm", (@count > 0 && "badge-info") || "badge-ghost opacity-40"]}
    >
      {@count}
    </span>
    """
  end

  defp matrix_cell(assigns) do
    assigns =
      assign(
        assigns,
        :authorized,
        MapSet.member?(assigns.matrix.cells, {assigns.user.id, assigns.host.id})
      )

    ~H"""
    <button
      id={"matrix-cell-#{@user.id}-#{@host.id}"}
      type="button"
      class={[
        "btn btn-square btn-xs border-0",
        (@authorized && "btn-success bg-success/20 text-success hover:bg-success/40") ||
          "btn-ghost text-base-content/25 hover:text-error"
      ]}
      phx-click="matrix-toggle"
      phx-value-user-id={@user.id}
      phx-value-host-id={@host.id}
      title={"#{@user.username} on #{@host.name} as #{@matrix_login}: " <>
        if(@authorized, do: "authorized — click to revoke", else: "not authorized — click to grant")}
    >
      <.icon :if={@authorized} name="hero-check" class="size-3.5" />
      <.icon :if={!@authorized} name="hero-x-mark" class="size-3.5" />
    </button>
    """
  end

  attr :all_authorizations, :list, required: true
  attr :users, :list, required: true
  attr :hosts, :list, required: true

  defp stats_view(assigns) do
    assigns = assign(assigns, :stats, stats_summary(assigns))

    ~H"""
    <div id="auth-stats" class="space-y-4">
      <div class="stats stats-vertical sm:stats-horizontal w-full bg-base-200 shadow-sm">
        <div class="stat">
          <div class="stat-title">Total grants</div>
          <div class="stat-value text-2xl" id="stat-auth-total">{@stats.total}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Active</div>
          <div class="stat-value text-2xl" id="stat-auth-active">{@stats.active}</div>
          <div class="stat-desc">user enabled, host not disabled</div>
        </div>
        <div class="stat">
          <div class="stat-title">Inactive</div>
          <div class="stat-value text-2xl" id="stat-auth-inactive">{@stats.inactive}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Login accounts</div>
          <div class="stat-value text-2xl" id="stat-auth-logins">{@stats.login_count}</div>
        </div>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div class="rounded-box bg-base-200 p-4">
          <h2 class="mb-2 text-sm font-semibold">Hosts by user access</h2>
          <p :if={@stats.top_hosts == []} class="text-sm opacity-60">No grants yet.</p>
          <ol class="space-y-1 text-sm">
            <li :for={{name, host_id, count} <- @stats.top_hosts} class="flex justify-between">
              <.link patch={~p"/authorizations?host_id=#{host_id}"} class="link link-hover">
                {name}
              </.link>
              <span class="tabular-nums opacity-70">{count} user(s)</span>
            </li>
          </ol>
        </div>
        <div class="rounded-box bg-base-200 p-4">
          <h2 class="mb-2 text-sm font-semibold">Users by host access</h2>
          <p :if={@stats.top_users == []} class="text-sm opacity-60">No grants yet.</p>
          <ol class="space-y-1 text-sm">
            <li :for={{name, user_id, count} <- @stats.top_users} class="flex justify-between">
              <.link patch={~p"/authorizations?user_id=#{user_id}"} class="link link-hover">
                {name}
              </.link>
              <span class="tabular-nums opacity-70">{count} host(s)</span>
            </li>
          </ol>
        </div>
      </div>
    </div>
    """
  end

  defp stats_summary(assigns) do
    auths = assigns.all_authorizations

    active =
      Enum.count(auths, fn auth ->
        auth.user != nil and auth.user.enabled and auth.host != nil and not auth.host.disabled
      end)

    %{
      total: length(auths),
      active: active,
      inactive: length(auths) - active,
      login_count: auths |> Enum.map(& &1.login) |> Enum.uniq() |> length(),
      top_hosts: top_by(auths, & &1.host, & &1.user_id, & &1.name),
      top_users: top_by(auths, & &1.user, & &1.host_id, & &1.username)
    }
  end

  # Top 5 entities by how many distinct counterparts hold a grant with them.
  defp top_by(auths, entity_fun, counterpart_fun, name_fun) do
    auths
    |> Enum.reject(&is_nil(entity_fun.(&1)))
    |> Enum.group_by(entity_fun, counterpart_fun)
    |> Enum.map(fn {entity, counterparts} ->
      {name_fun.(entity), entity.id, counterparts |> Enum.uniq() |> length()}
    end)
    |> Enum.sort_by(fn {name, _id, count} -> {-count, name} end)
    |> Enum.take(5)
  end

  attr :all_authorizations, :list, required: true

  defp list_stats(assigns) do
    auths = assigns.all_authorizations

    active =
      Enum.count(auths, fn auth ->
        auth.user != nil and auth.user.enabled and auth.host != nil and not auth.host.disabled
      end)

    assigns =
      assign(assigns,
        total: length(auths),
        active: active,
        inactive: length(auths) - active,
        user_count: auths |> Enum.map(& &1.user_id) |> Enum.uniq() |> length(),
        host_count: auths |> Enum.map(& &1.host_id) |> Enum.uniq() |> length()
      )

    ~H"""
    <div id="list-stats" class="stats stats-vertical sm:stats-horizontal w-full bg-base-200 shadow-sm">
      <div class="stat py-2">
        <div class="stat-title">Total</div>
        <div class="stat-value text-2xl">{@total}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title">Active</div>
        <div class="stat-value text-2xl text-success">{@active}</div>
        <div class="stat-desc">user enabled, host not disabled</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title">Inactive</div>
        <div class="stat-value text-2xl text-warning">{@inactive}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title">Users</div>
        <div class="stat-value text-2xl">{@user_count}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title">Hosts</div>
        <div class="stat-value text-2xl">{@host_count}</div>
      </div>
    </div>
    """
  end

  attr :bulk, :map, required: true
  attr :users, :list, required: true
  attr :hosts, :list, required: true

  defp bulk_modal(assigns) do
    assigns =
      assigns
      |> assign(
        :visible_users,
        assigns.users
        |> Enum.filter(& &1.enabled)
        |> filter_by_name(assigns.bulk.user_search, & &1.username)
      )
      |> assign(
        :visible_hosts,
        filter_by_name(assigns.hosts, assigns.bulk.host_search, & &1.name)
      )

    ~H"""
    <.modal id="bulk-grant-modal" box_class="max-w-3xl" on_cancel={JS.push("cancel")}>
      <:title>Bulk grant access</:title>

      <p class="mb-3 text-sm opacity-70">
        Grants the login to every selected user on every selected host.
        Pairs that already hold this grant are skipped.
      </p>

      <div class="grid gap-4 sm:grid-cols-2">
        <div>
          <div class="mb-1 flex items-center justify-between">
            <span class="text-sm font-medium">
              Users <span class="ml-1 opacity-60">{MapSet.size(@bulk.user_ids)} selected</span>
            </span>
            <div class="join">
              <button type="button" class="btn btn-ghost btn-xs join-item" phx-click="bulk-all-users">
                All enabled
              </button>
              <button type="button" class="btn btn-ghost btn-xs join-item" phx-click="bulk-no-users">
                None
              </button>
            </div>
          </div>
          <form id="bulk-user-search" phx-change="bulk-user-search" class="mb-1">
            <input
              type="search"
              name="q"
              value={@bulk.user_search}
              placeholder="Filter users…"
              class="input input-sm w-full"
              phx-debounce="150"
              autocomplete="off"
            />
          </form>
          <div class="h-56 overflow-y-auto overflow-x-hidden rounded-box border border-base-300 bg-base-200 p-1">
            <p :if={@visible_users == []} class="px-2 py-1 text-sm opacity-60">No matching users.</p>
            <label
              :for={user <- @visible_users}
              class="flex cursor-pointer items-center gap-2 rounded px-2 py-1 hover:bg-base-300"
            >
              <input
                type="checkbox"
                id={"bulk-user-#{user.id}"}
                class="checkbox checkbox-sm flex-none"
                checked={MapSet.member?(@bulk.user_ids, user.id)}
                phx-click="bulk-toggle-user"
                phx-value-id={user.id}
              />
              <span class="truncate text-sm" title={user.username}>{user.username}</span>
            </label>
          </div>
        </div>

        <div>
          <div class="mb-1 flex items-center justify-between">
            <span class="text-sm font-medium">
              Hosts <span class="ml-1 opacity-60">{MapSet.size(@bulk.host_ids)} selected</span>
            </span>
            <div class="join">
              <button type="button" class="btn btn-ghost btn-xs join-item" phx-click="bulk-all-hosts">
                All
              </button>
              <button type="button" class="btn btn-ghost btn-xs join-item" phx-click="bulk-no-hosts">
                None
              </button>
            </div>
          </div>
          <form id="bulk-host-search" phx-change="bulk-host-search" class="mb-1">
            <input
              type="search"
              name="q"
              value={@bulk.host_search}
              placeholder="Filter hosts…"
              class="input input-sm w-full"
              phx-debounce="150"
              autocomplete="off"
            />
          </form>
          <div class="h-56 overflow-y-auto overflow-x-hidden rounded-box border border-base-300 bg-base-200 p-1">
            <p :if={@visible_hosts == []} class="px-2 py-1 text-sm opacity-60">No matching hosts.</p>
            <label
              :for={host <- @visible_hosts}
              class="flex cursor-pointer items-center gap-2 rounded px-2 py-1 hover:bg-base-300"
            >
              <input
                type="checkbox"
                id={"bulk-host-#{host.id}"}
                class="checkbox checkbox-sm flex-none"
                checked={MapSet.member?(@bulk.host_ids, host.id)}
                phx-click="bulk-toggle-host"
                phx-value-id={host.id}
              />
              <span class="truncate text-sm" title={host.name}>{host.name}</span>
              <span :if={host.disabled} class="badge badge-warning badge-xs flex-none">
                disabled
              </span>
            </label>
          </div>
        </div>
      </div>

      <form
        id="bulk-grant-form"
        phx-change="bulk-change"
        phx-submit="bulk-save"
        class="mt-3 space-y-2"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            type="text"
            name="bulk[login]"
            value={@bulk.login}
            label="Remote login"
            placeholder="e.g. deploy"
            required
          />
          <.input
            type="text"
            name="bulk[options]"
            value={@bulk.options}
            label="authorized_keys options"
            placeholder={~s(e.g. no-pty,from="10.0.0.0/8")}
          />
        </div>

        <div
          id="bulk-preview"
          class="flex items-center gap-2 rounded-box bg-base-200 px-3 py-2 text-sm"
        >
          <span class={["badge", (@bulk.new_count > 0 && "badge-success") || "badge-ghost"]}>
            {@bulk.new_count} new grant(s)
          </span>
          <span class="badge badge-ghost">{@bulk.existing_count} already exist</span>
          <span class="opacity-60">
            {MapSet.size(@bulk.user_ids)} user(s) × {MapSet.size(@bulk.host_ids)} host(s)
          </span>
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          <button type="submit" class="btn btn-primary" disabled={@bulk.new_count == 0}>
            Grant access
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  defp filter_by_name(items, search, name_fun) do
    case search |> String.trim() |> String.downcase() do
      "" ->
        items

      needle ->
        Enum.filter(items, &String.contains?(String.downcase(name_fun.(&1)), needle))
    end
  end
end
