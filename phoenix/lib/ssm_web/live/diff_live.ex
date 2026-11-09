defmodule SsmWeb.DiffLive do
  @moduledoc """
  Diff viewer: per-host comparison of the DB's expected authorized_keys
  against what is on the host, with single-host sync and sync-all — the
  React DiffPage. Disabled hosts are marked and never touched
  (non-negotiable rule #4); readonly logins surface as badges. A host-wide
  readonly marker stops a sync before any write; a login's own
  `user_readonly` skips only that login, the others are written and the
  sync reports as failed naming the skipped logins (a partial sync,
  `Ssm.Diffs.sync_host/2`). Syncs run in `Ssm.Diffs.SyncRunner`, unlinked
  from the page, which audit-logs every outcome (`Ssm.Diffs.SyncAudit`) even
  when the page is closed mid-sync and refuses a host that is already
  syncing.

  Unauthorized keys found on a host can be legitimized in place (database
  writes only, the host itself is untouched until the next sync): a key
  belonging to a known user gets an "Allow" button that grants that user the
  login; an unknown key can be assigned to a user, which also grants the
  login if missing.

  Only the "Sync" buttons write to a host, and each asks first with what the
  write adds and removes (`SsmWeb.SyncConfirm`). Every other action here (Allow,
  Add key, Remove <user>) changes the database and reloads the diff; the
  host follows at the next sync.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity
  alias Ssm.Activity.Actions
  alias Ssm.Authorizations
  alias Ssm.Diffs
  alias Ssm.Diffs.HostCheck
  alias Ssm.Diffs.HostChecks
  alias Ssm.Diffs.HostDiff
  alias Ssm.Diffs.StatusCache
  alias Ssm.Diffs.SyncCheck
  alias Ssm.Diffs.SyncRunner
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias Ssm.Hosts.ManagedLogins
  alias Ssm.HostStatus
  alias Ssm.Users
  alias Ssm.Users.KeyAssignment
  alias Ssm.Users.KeyParser
  alias Ssm.Users.UserKey
  alias SsmWeb.ErrorText
  alias SsmWeb.Layouts
  alias SsmWeb.StatusText
  alias SsmWeb.SyncConfirm

  # Result filters: value, label. `kinds/1` maps a filter to the result
  # kinds it shows; `result_kind/2` classifies one host.
  @filters [
    {"all", "All hosts"},
    {"needs_sync", "Needs sync"},
    {"auth", "Key not accepted"},
    {"unreachable", "Unreachable / timeout"},
    {"dns", "Name does not resolve"},
    {"other", "Other errors"},
    {"unchecked", "Not checked"},
    {"disabled", "Disabled"}
  ]

  @kinds ~w(synced needs_sync auth unreachable dns other unchecked disabled)a

  # Opening the page never opens an SSH connection: every host shows its last
  # known result (`Ssm.HostStatus.derive/3`: this node's status cache, else
  # the stored check in `host_checks`); `:loading` while a check runs. Hosts are read only on an explicit action: "Check" on a
  # row, "Check all" (asks first), or the detail view of one selected host.
  @impl true
  # Only hosts in the user's scope (ADR-0012) are listed, and every action
  # picks its host from that list: an out-of-scope id acts as a missing one.
  def mount(_params, _session, socket) do
    scope = scope(socket)
    hosts = Hosts.list_hosts(scope)
    cached = StatusCache.all()
    checks = HostChecks.stored(scope)

    statuses = Map.new(hosts, &{&1.id, HostStatus.derive(&1, cached[&1.id], checks[&1.id])})

    socket =
      socket
      |> assign(page_title: "Sync")
      |> assign(hosts: hosts, statuses: statuses, checks: checks, syncing: false)
      |> assign(detail: nil, detail_error: nil, detail_loading: false)
      |> assign(key_owners: %{}, host_auths: %{}, keyfiles: %{}, unknown_key: nil)
      |> assign(remove_user: nil)
      |> assign(diff_search: "", diff_sort: nil, diff_filter: "all")

    {:ok, socket}
  end

  # Viewers get what is already known; anything that would open an SSH
  # connection to a host is for operators and admins.
  defp read_only?(socket), do: socket.assigns.current_user.role == "viewer"

  @impl true
  def handle_params(params, _uri, socket) do
    selected = fresh_host(socket, params["host_id"])

    view = if params["view"] == "cards", do: "cards", else: "list"

    filter =
      if params["filter"] in Enum.map(@filters, &elem(&1, 0)), do: params["filter"], else: "all"

    socket =
      assign(socket,
        selected: selected,
        detail: nil,
        detail_error: nil,
        diff_view: view,
        diff_search: params["q"] || "",
        diff_filter: filter
      )

    socket =
      cond do
        selected && read_only?(socket) ->
          assign(socket, :detail_error, "Live diffs need an operator account (read-only access).")

        (connected?(socket) and selected) && !selected.disabled ->
          start_detail_async(socket, selected)

        true ->
          socket
      end

    {:noreply, socket}
  end

  ## Async work

  # Each host's result streams back the moment it is known (`{:host_status,
  # id, status}` messages) instead of one all-or-nothing batch — with dozens
  # of hosts and a 120s timeout on dead ones, a single batch kept every badge
  # on "checking…" for minutes.
  # Every result is stored as the host's check (`HostChecks.check_host/2`), so
  # the page shows it again after a reload without a new SSH connection.
  defp start_statuses_async(socket, hosts) do
    ids = Enum.map(hosts, & &1.id)
    parent = self()

    concurrency = check_concurrency()

    start_async(socket, :statuses, fn ->
      owners = HostChecks.owners()

      ids
      |> Task.async_stream(
        fn id -> send(parent, {:host_check, id, check(id, owners)}) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()
    end)
  end

  defp check(id, owners) do
    HostChecks.check_host(id, owners: owners)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
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

  defp summarize(%HostDiff{} = diff), do: HostStatus.from_sync_status(SyncCheck.status(diff))

  @impl true
  def handle_async(:statuses, {:ok, _done}, socket) do
    {:noreply, socket}
  end

  def handle_async(:statuses, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, ErrorText.crashed("The status check", reason))}
  end

  def handle_async(:detail, {:ok, result}, socket) do
    socket = assign(socket, :detail_loading, false)

    case result do
      {:ok, %HostDiff{} = diff} ->
        statuses = Map.put(socket.assigns.statuses, diff.host_id, summarize(diff))
        # key base64 -> %UserKey{user: …}: who owns a line (links, Allow)
        owners = Map.new(Users.list_keys(), &{&1.key_base64, &1})

        # the explicit read of this host is stored as its check
        checks =
          case HostChecks.record(diff.host_id, diff) do
            {:ok, check} -> Map.put(socket.assigns.checks, diff.host_id, check)
            {:error, _} -> socket.assigns.checks
          end

        {:noreply,
         assign(socket,
           detail: diff,
           detail_error: nil,
           statuses: statuses,
           checks: checks,
           key_owners: owners,
           host_auths: host_auths(socket, diff),
           keyfiles: keyfiles(socket, diff)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, detail: nil, detail_error: format_reason(reason))}
    end
  end

  def handle_async(:detail, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:detail, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(detail_loading: false, detail_error: ErrorText.crashed("Reading the host", reason))}
  end

  def handle_async(:remove_login, {:ok, {host, login, result}}, socket) do
    socket =
      case result do
        {:ok, _} ->
          put_flash(socket, :info, "Removed login #{login} from #{host.name}.")

        {:error, reason} ->
          put_flash(
            socket,
            :error,
            "Authorizations of #{login} removed, but ssm still manages the login: " <>
              ErrorText.reason(reason)
          )
      end

    {:noreply, refresh_detail(socket)}
  end

  def handle_async(:remove_login, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, ErrorText.crashed("Removing the login", reason))}
  end

  # the runner (Ssm.Diffs.SyncRunner) has audited the outcome already
  def handle_async(:sync, {:ok, {host, run}}, socket) do
    socket = assign(socket, :syncing, false)

    case sync_outcome(run) do
      :busy ->
        {:noreply, put_flash(socket, :error, already_running(host))}

      {:ok, synced} ->
        keys = synced |> Enum.map(& &1.written_keys) |> Enum.sum()

        socket =
          socket
          |> put_flash(
            :info,
            "Synced #{host.name}: #{length(synced)} logins, #{keys} keys written."
          )
          |> refresh_after_sync(host)

        {:noreply, socket}

      {:error, reason} ->
        if Ssm.Diffs.partial_sync?(reason) do
          {:noreply,
           socket
           |> put_flash(
             :warning,
             "Sync of #{host.name} partly done: #{format_reason(reason)}"
           )
           |> refresh_after_sync(host)}
        else
          {:noreply,
           put_flash(socket, :error, "Sync of #{host.name} failed: #{format_reason(reason)}")}
        end
    end
  end

  def handle_async(:sync, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, ErrorText.crashed("Sync", reason))}
  end

  def handle_async(:sync_all, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> put_flash(:error, ErrorText.crashed("Sync all", reason))}
  end

  def handle_async(:sync_all, {:ok, {:ok, %{results: results, busy: busy}}}, socket) do
    socket = assign(socket, :syncing, false)

    ok = Enum.count(results, fn {_host, result} -> match?({:ok, _}, result) end)
    failed = length(results) - ok

    # re-check only the hosts that were synced, not the whole fleet
    hosts = Enum.map(results, fn {host, _result} -> host end)

    message =
      if failed == 0 do
        "Sync all done: #{ok} hosts synced."
      else
        failed_names =
          for {host, result} <- results, not match?({:ok, _}, result), do: host.name

        "Sync all done: #{ok} synced, #{failed} failed: #{SsmWeb.Names.short_list(failed_names)}. " <>
          "Each failure is in Activity."
      end

    message = if busy == [], do: message, else: message <> " #{length(busy)} already running."

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
     |> put_flash(:error, ErrorText.crashed("Sync all", reason))}
  end

  @impl true
  def handle_info({:host_check, host_id, {:ok, %HostCheck{} = check}}, socket) do
    {:noreply,
     socket
     |> update(:checks, &Map.put(&1, host_id, check))
     |> update(:statuses, &Map.put(&1, host_id, HostStatus.from_check(check)))}
  end

  def handle_info({:host_check, host_id, {:error, :disabled}}, socket) do
    {:noreply,
     socket
     |> update(:checks, &Map.delete(&1, host_id))
     |> update(:statuses, &Map.put(&1, host_id, :disabled))}
  end

  def handle_info({:host_check, host_id, {:error, reason}}, socket) do
    status = HostStatus.from_error(format_reason(reason))
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
    {:noreply, push_patch(socket, to: ~p"/diff?#{diff_query(socket, host_id: id)}")}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{diff_query(socket, host_id: nil)}")}
  end

  # stop waiting for a slow host; the read itself is time-bounded on the host
  def handle_event("cancel-read", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:detail)
     |> assign(detail_loading: false, detail_error: "Reading the host was cancelled.")}
  end

  def handle_event("refresh", _params, socket) do
    case fresh_selected(socket) do
      %Host{disabled: false} = host -> {:noreply, start_detail_async(socket, host)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("diff-view", %{"view" => view}, socket) when view in ~w(cards list) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{diff_query(socket, view: view)}")}
  end

  # search and filter live in the URL (like the hosts and users lists)
  def handle_event("diff-search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{diff_query(socket, q: q)}")}
  end

  def handle_event("diff-filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: ~p"/diff?#{diff_query(socket, filter: filter)}")}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    {:noreply, update(socket, :diff_sort, &SsmWeb.TableSort.toggle(&1, key))}
  end

  def handle_event("recheck-row", %{"id" => id}, socket) do
    case fresh_host(socket, id) do
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
    case fresh_host(socket, id) do
      %Host{disabled: false} = host ->
        {:noreply, start_sync(socket, host)}

      %Host{disabled: true} = host ->
        {:noreply, put_flash(socket, :error, "Host #{host.name} is disabled.")}

      nil ->
        {:noreply, socket}
    end
  end

  # "Check all" (asks first in the page): reads every enabled host over SSH.
  def handle_event("recheck", _params, socket) do
    hosts = socket |> fresh_hosts() |> Enum.reject(& &1.disabled)

    statuses =
      Enum.reduce(hosts, socket.assigns.statuses, &Map.put(&2, &1.id, :loading))

    {:noreply,
     socket
     |> assign(:statuses, statuses)
     |> start_statuses_async(hosts)}
  end

  def handle_event("sync", _params, socket) do
    case fresh_selected(socket) do
      %Host{disabled: false} = host ->
        {:noreply, start_sync(socket, host)}

      %Host{disabled: true} = host ->
        {:noreply, put_flash(socket, :error, "Host #{host.name} is disabled.")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("allow-key", %{"login" => login, "index" => index}, socket) do
    with %Host{disabled: false} = host <- fresh_selected(socket),
         {:ok, item} <- find_extra_item(socket, login, index),
         {:ok, parsed} <- KeyParser.parse_authorized_line(item.line),
         %UserKey{} = key <- Users.get_key_by_base64(parsed.key_base64) do
      allow_grant(socket, host, key.user, login)
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot authorize this key.")}
    end
  end

  # "Remove login from host" (admin, a login the host does not know): delete
  # the login's manual authorizations here, then forget the managed login
  # even though the host cannot confirm there is no file
  # (`ManagedLogins.forget/5`, `unknown_login: :forget`).
  def handle_event("remove-login", %{"login" => login}, socket) do
    with false <- read_only?(socket),
         true <- socket.assigns.current_user.role == "admin",
         %Host{disabled: false} = host <- fresh_selected(socket),
         :ok <- delete_login_authorizations(socket, host, login) do
      actor = socket.assigns.current_user.actor

      {:noreply,
       start_async(socket, :remove_login, fn ->
         {host, login, ManagedLogins.forget(Ssm.Ssh, host, login, actor, unknown_login: :forget)}
       end)}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "Cannot remove this login.")}
    end
  end

  # "Remove <user>": a dialog lists the login's lines and marks every key of
  # that SSH user (a user can hold several); confirming deletes the manual
  # authorization (a grant row only through its grant), optionally syncs
  def handle_event("remove-user-open", %{"id" => id}, socket) do
    with false <- read_only?(socket),
         {id, ""} <- Integer.parse(to_string(id)),
         %Authorizations.Authorization{grant_id: nil} = auth <-
           Authorizations.get_authorization(scope(socket), id),
         %Users.User{} = user <- Users.get_user(auth.user_id) do
      {:noreply,
       assign(socket, :remove_user, %{
         auth_id: auth.id,
         user_id: auth.user_id,
         username: user.username,
         login: auth.login
       })}
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot remove this access.")}
    end
  end

  def handle_event("remove-user-cancel", _params, socket),
    do: {:noreply, assign(socket, :remove_user, nil)}

  def handle_event("remove-user-confirm", _params, %{assigns: %{remove_user: %{} = r}} = socket) do
    socket = assign(socket, :remove_user, nil)

    with false <- read_only?(socket),
         %Authorizations.Authorization{} = auth <-
           Authorizations.get_authorization(scope(socket), r.auth_id),
         {:ok, _} <- Authorizations.delete_authorization(scope(socket), auth) do
      Ssm.Activity.Entries.authorization(:delete, auth, socket.assigns.current_user.actor)
      host = fresh_selected(socket)

      cond do
        host ->
          {:noreply,
           socket
           |> put_flash(:info, "Removed #{r.username} from #{r.login}. Sync to update the host.")
           |> start_detail_async(host)}

        true ->
          {:noreply, socket}
      end
    else
      {:error, {:grant_takeover, _}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A grant covers this user and login without this row's restrictions; " <>
             "remove the restrictions first or delete the grant."
         )}

      {:error, :grant_row} ->
        {:noreply, put_flash(socket, :error, "This access comes from a grant; delete the grant.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Cannot remove this access.")}
    end
  end

  def handle_event("remove-user-confirm", _params, socket), do: {:noreply, socket}

  def handle_event("unknown-key-open", %{"login" => login, "index" => index}, socket) do
    with %Host{disabled: false} <- fresh_selected(socket),
         {:ok, item} <- find_extra_item(socket, login, index),
         {:ok, parsed} <- KeyParser.parse_authorized_line(item.line) do
      {:noreply,
       assign(socket, :unknown_key, %{
         login: login,
         line: item.line,
         parsed: parsed,
         users: Users.list_users(),
         # "Create user" is the default, prefilled from the key comment
         user_id: "new",
         username: KeyAssignment.suggest_username(parsed.name),
         key_name: parsed.name || "",
         error: nil
       })}
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot assign this key.")}
    end
  end

  def handle_event("unknown-key-cancel", _params, socket) do
    {:noreply, assign(socket, :unknown_key, nil)}
  end

  def handle_event("unknown-key-change", %{"assign" => params}, socket) do
    case socket.assigns.unknown_key do
      %{} = unknown -> {:noreply, assign(socket, :unknown_key, put_form(unknown, params))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unknown-key-assign", %{"assign" => params}, socket) do
    with %Host{disabled: false} = host <- fresh_selected(socket),
         %{} = unknown <- socket.assigns.unknown_key,
         {:ok, user} <- assign_target(params["user_id"]) do
      assign_unknown_key(socket, host, user, put_form(unknown, params))
    else
      _ -> {:noreply, put_flash(socket, :error, "Select a user to assign this key to.")}
    end
  end

  def handle_event("sync_all", %{}, %{assigns: %{syncing: true}} = socket) do
    {:noreply, put_flash(socket, :error, "A sync is already running.")}
  end

  def handle_event("sync_all", _params, socket) do
    actor = socket.assigns.current_user.actor

    to_sync =
      socket
      |> fresh_hosts()
      |> Enum.reject(& &1.disabled)
      |> Enum.filter(fn host ->
        match?({:drift, _, _}, socket.assigns.statuses[host.id])
      end)

    if to_sync == [] do
      {:noreply, put_flash(socket, :info, "Nothing to sync.")}
    else
      {:noreply,
       socket
       |> assign(:syncing, true)
       |> start_async(:sync_all, fn -> SyncRunner.run(to_sync, actor) end)}
    end
  end

  # The sync and its audit entry run in Ssm.Diffs.SyncRunner, not in this
  # page's task: closing the page only stops the waiting. The runner refuses
  # a host that is already syncing (another page, another tab); this page
  # also refuses a second start while it waits for one.
  defp start_sync(%{assigns: %{syncing: true}} = socket, host),
    do: put_flash(socket, :error, already_running(host))

  defp start_sync(socket, host) do
    actor = socket.assigns.current_user.actor

    socket
    |> assign(:syncing, true)
    |> start_async(:sync, fn -> {host, SyncRunner.run([host], actor)} end)
  end

  defp already_running(host), do: "A sync of #{host.name} is already running."

  defp sync_outcome({:ok, %{results: [{_host, outcome}]}}), do: outcome
  defp sync_outcome({:ok, %{results: [], busy: [_ | _]}}), do: :busy
  defp sync_outcome({:error, _} = error), do: error

  ## Scope: every event re-reads its host through the user's scope (ADR-0012),
  ## never from the mount-time list, so a host that left the scope is missing.

  defp scope(socket), do: Ssm.Scope.of(socket.assigns.current_user)

  defp fresh_hosts(socket), do: Hosts.list_hosts(scope(socket))

  defp fresh_host(socket, id) when is_integer(id), do: Hosts.get_host(scope(socket), id)

  defp fresh_host(socket, id) when is_binary(id) do
    case parse_id(id) do
      {:ok, id} -> fresh_host(socket, id)
      :error -> nil
    end
  end

  defp fresh_host(_socket, _id), do: nil

  defp fresh_selected(%{assigns: %{selected: %Host{id: id}}} = socket), do: fresh_host(socket, id)
  defp fresh_selected(_socket), do: nil

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
      case Authorizations.create_authorization(Ssm.Scope.of(socket.assigns.current_user), %{
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

  # "new" creates a user in the same transaction; otherwise an existing one
  defp assign_target("new"), do: {:ok, :new}

  defp assign_target(user_id) do
    with {:ok, id} <- parse_id(user_id),
         %Ssm.Users.User{} = user <- Users.get_user(id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp put_form(unknown, params) do
    %{
      unknown
      | user_id: Map.get(params, "user_id", unknown.user_id),
        username: Map.get(params, "username", unknown.username),
        key_name: Map.get(params, "key_name", unknown.key_name)
    }
  end

  # User (when new), key and grant in one transaction (Ssm.Users.KeyAssignment);
  # an error keeps the dialog open with the message.
  defp assign_unknown_key(socket, host, user, unknown) do
    result =
      KeyAssignment.assign(%{
        user: user,
        username: unknown.username,
        key_name: unknown.key_name,
        parsed: unknown.parsed,
        host_id: host.id,
        login: unknown.login,
        scope: Ssm.Scope.of(socket.assigns.current_user),
        role: socket.assigns.current_user.role,
        actor: socket.assigns.current_user.actor
      })

    case result do
      {:ok, %{user: user, key: key} = done} ->
        if done.user_created?, do: log_user_create(socket, user)
        log_key_assign(socket, user, key)
        if done.granted?, do: log_allow(socket, user, host, unknown.login)

        {:noreply,
         socket
         |> assign(:unknown_key, nil)
         |> put_flash(
           :info,
           "Assigned the key to #{user.username} for #{unknown.login} on #{host.name}."
         )
         |> start_detail_async(host)}

      {:error, {_field, message}} ->
        {:noreply, assign(socket, :unknown_key, %{unknown | error: message})}
    end
  end

  defp log_allow(socket, user, host, login) do
    Activity.log(%{
      activity_type: "auth",
      action: Actions.name(:create),
      target: "#{user.username}@#{host.name}:#{login}",
      host_id: host.id,
      actor_username: socket.assigns.current_user.actor,
      user_id: user.id
    })
  end

  defp log_user_create(socket, user) do
    Activity.log(%{
      activity_type: "user",
      action: Actions.name(:create),
      target: user.username,
      actor_username: socket.assigns.current_user.actor,
      user_id: user.id,
      details: %{via: "assign unknown key"}
    })
  end

  defp log_key_assign(socket, user, key) do
    Activity.log(%{
      activity_type: "key",
      action: Actions.name(:create),
      target: key.name || key.key_type,
      actor_username: socket.assigns.current_user.actor,
      user_id: user.id,
      details: %{key_type: key.key_type}
    })
  end

  # {:known, user} | :unknown | :invalid for an extra_on_host line.
  # {user_id, login} -> %Authorization{} of the shown host (in scope)
  defp host_auths(socket, %HostDiff{host_id: id}) do
    socket
    |> scope()
    |> Authorizations.list_authorizations(host_id: id)
    |> Map.new(&{{&1.user_id, &1.login}, &1})
  end

  # login -> the authorized_keys a full sync would write (copy button)
  defp keyfiles(socket, %HostDiff{} = diff) do
    case socket.assigns.selected do
      %Host{id: id} = host when id == diff.host_id ->
        Map.new(diff.logins, fn login ->
          host_lines = for i <- login.items, i.status != :missing_on_host, do: i.line
          {login.login, Diffs.generated_keyfile(host, login.login, host_lines)}
        end)

      _other ->
        %{}
    end
  end

  defp owner_auth(%UserKey{user_id: uid}, login, auths), do: Map.get(auths, {uid, login})
  defp owner_auth(_key, _login, _auths), do: nil

  defp login_items(%HostDiff{logins: logins}, login),
    do: Enum.find_value(logins, [], &(&1.login == login && &1.items))

  defp login_items(_detail, _login), do: []

  defp owned_by?(line, owners, user_id) do
    match?(%UserKey{user_id: ^user_id}, line_key(line, owners))
  end

  # a manual row can be deleted here; a grant row only through its grant
  defp revocable?(%Authorizations.Authorization{grant_id: nil}), do: true
  defp revocable?(_auth), do: false

  # the database key behind a line (nil: unknown or unparsable)
  defp line_key(line, owners) do
    case KeyParser.parse_authorized_line(line) do
      {:ok, parsed} -> Map.get(owners, parsed.key_base64)
      {:error, _} -> nil
    end
  end

  defp extra_key_info(line, owners) do
    case KeyParser.parse_authorized_line(line) do
      {:ok, parsed} ->
        case Map.get(owners, parsed.key_base64) do
          nil -> :unknown
          key -> {:known, key.user}
        end

      {:error, _reason} ->
        :invalid
    end
  end

  ## Helpers

  defp refresh_detail(socket) do
    case fresh_selected(socket) do
      %Host{} = host -> start_detail_async(socket, host)
      nil -> socket
    end
  end

  # every manual row of `login` on `host`; a grant row stops it (only its grant removes it)
  defp delete_login_authorizations(socket, host, login) do
    auths =
      socket
      |> scope()
      |> Authorizations.list_authorizations(host_id: host.id)
      |> Enum.filter(&(&1.login == login))

    if Enum.any?(auths, & &1.grant_id) do
      {:error, "#{login} has access from a grant on this host; delete the grant first."}
    else
      Enum.reduce_while(auths, :ok, fn auth, :ok ->
        case Authorizations.delete_authorization(scope(socket), auth) do
          {:ok, _} ->
            Ssm.Activity.Entries.authorization(:delete, auth, socket.assigns.current_user.actor)
            {:cont, :ok}

          {:error, {:grant_takeover, _}} ->
            {:halt,
             {:error,
              "A grant covers #{login} without the restrictions of a row; " <>
                "remove the restrictions first or delete the grant."}}

          {:error, _} ->
            {:halt, {:error, "Could not delete the authorizations of #{login}."}}
        end
      end)
    end
  end

  defp remove_login_confirm(host, login, host_auths) do
    count = Enum.count(host_auths, fn {{_user_id, l}, _auth} -> l == login end)
    entries = if count == 1, do: "1 authorization", else: "#{count} authorizations"

    "Remove login #{login} from #{host.name}? ssm deletes its #{entries} here and stops " <>
      "managing #{login} on this host. The host says it does not know #{login}. " <>
      "If that is only a directory outage (LDAP/AD/SSSD), an old authorized_keys of " <>
      "#{login} can come back with the login, and a sync no longer empties it."
  end

  # The page's URL query: defaults are left out (list view, no search, all).
  defp diff_query(socket, overrides) do
    a = socket.assigns

    [
      view: a.diff_view,
      q: a.diff_search,
      filter: a.diff_filter,
      host_id: a.selected && a.selected.id
    ]
    |> Keyword.merge(overrides)
    |> Enum.reject(fn {key, value} ->
      value in [nil, ""] or {key, value} in [view: "list", filter: "all"]
    end)
  end

  defp format_reason({_code, message}) when is_binary(message), do: message
  defp format_reason(:not_found), do: "host not found"
  defp format_reason(other), do: ErrorText.reason(other)

  # Hosts for the list view: filtered by result, searched (name/address) and
  # sorted.
  defp list_rows(assigns) do
    assigns
    |> card_rows()
    |> filter_hosts(assigns.diff_search)
    |> SsmWeb.TableSort.sort(assigns.diff_sort, diff_sorters(assigns.statuses))
  end

  # Hosts for the card view: filtered by result.
  defp card_rows(assigns) do
    Enum.filter(assigns.hosts, &(result_kind(&1, assigns) in kinds(assigns.diff_filter)))
  end

  defp kinds("all"), do: @kinds
  defp kinds(filter), do: [String.to_existing_atom(filter)]

  defp result_kind(%Host{id: id}, %{statuses: statuses, checks: checks}) do
    case statuses[id] do
      :disabled -> :disabled
      :synced -> :synced
      {:drift, _, _} -> :needs_sync
      {:auth_failed, _} -> :auth
      {_error, message} when is_binary(message) -> HostCheck.kind(checks[id]) || :other
      _unchecked_or_loading -> :unchecked
    end
  end

  defp filter_options(assigns) do
    counts = Enum.frequencies_by(assigns.hosts, &result_kind(&1, assigns))

    Enum.map(@filters, fn
      {"all", label} -> {"#{label} (#{length(assigns.hosts)})", "all"}
      {value, label} -> {"#{label} (#{counts[String.to_existing_atom(value)] || 0})", value}
    end)
  end

  defp auth_count(assigns), do: Enum.count(assigns.hosts, &(result_kind(&1, assigns) == :auth))

  defp checkable_count(hosts), do: Enum.count(hosts, &(not &1.disabled))

  # "checked 3 h ago" / "never checked" from the stored check.
  attr :check, :any, required: true
  attr :id, :string, default: nil

  defp check_age(assigns) do
    ~H"""
    <span id={@id} class="block text-xs opacity-60">
      {if @check, do: "checked #{ago(@check.checked_at)}", else: "never checked"}
    </span>
    """
  end

  defp ago(at), do: SyncConfirm.ago(at)

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

  defp diff_status_rank({:drift, _, _}), do: 1
  defp diff_status_rank(:synced), do: 2
  defp diff_status_rank(:loading), do: 3
  defp diff_status_rank(:unchecked), do: 3
  defp diff_status_rank(:disabled), do: 4
  defp diff_status_rank({_error, _message}), do: 0

  defp diff_count({:drift, missing, extra}), do: missing + extra
  defp diff_count(:synced), do: 0
  defp diff_count(_status), do: nil

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", StatusText.class(@status)]}>{StatusText.label(@status)}</span>
    """
  end

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
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:diff}
    >
      <.header>
        Sync
        <:subtitle>Expected authorized_keys (database) vs actual (host)</:subtitle>
        <:actions :if={!@selected}>
          <.button
            id="recheck-all"
            phx-click="recheck"
            disabled={@syncing}
            data-confirm={"Check all #{checkable_count(@hosts)} hosts? ssm connects to each over SSH and reads its authorized_keys (nothing is written)."}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Check all
          </.button>
          <.button
            id="sync-all"
            phx-click="sync_all"
            disabled={@syncing}
            data-confirm={SyncConfirm.all(@hosts, @statuses, @checks)}
            data-confirm-type={"sync #{SyncConfirm.drifting_count(@hosts, @statuses)}"}
            data-confirm-label="Sync all"
          >
            <.icon
              name="hero-cloud-arrow-up"
              class={["size-4", @syncing && "motion-safe:animate-spin"]}
            /> Sync all
          </.button>
        </:actions>
      </.header>

      <p :if={@hosts == []} class="text-sm opacity-60">No hosts configured.</p>

      <.link
        :if={@selected}
        id="diff-back"
        patch={~p"/diff?#{[view: @diff_view]}"}
        class="link text-sm"
      >
        ← all hosts
      </.link>

      <div
        :if={!@selected and auth_count(assigns) > 0}
        id="key-not-accepted"
        class="alert alert-warning text-sm"
      >
        <.icon name="hero-key" class="size-4" />
        <span>
          {auth_count(assigns)} {if auth_count(assigns) == 1, do: "host", else: "hosts"} did not
          accept ssm's key at the last check.
        </span>
        <button class="btn btn-ghost btn-xs" phx-click="diff-filter" phx-value-filter="auth">
          Show
        </button>
      </div>

      <div :if={!@selected} class="flex flex-wrap items-center gap-3">
        <div id="diff-view-switcher" class="join">
          <button
            id="diff-view-list"
            class={["btn btn-sm join-item", @diff_view == "list" && "btn-primary"]}
            phx-click="diff-view"
            phx-value-view="list"
          >
            <.icon name="hero-bars-3" class="size-4" /> List
          </button>
          <button
            id="diff-view-cards"
            class={["btn btn-sm join-item", @diff_view == "cards" && "btn-primary"]}
            phx-click="diff-view"
            phx-value-view="cards"
          >
            <.icon name="hero-squares-2x2" class="size-4" /> Cards
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
            aria-label="Search hosts by name or address"
            class="input input-sm w-full"
            phx-debounce="200"
            autocomplete="off"
          />
        </form>
        <form id="diff-filter" phx-change="diff-filter" class="w-64">
          <select name="filter" class="select select-sm w-full" aria-label="Filter by result">
            {Phoenix.HTML.Form.options_for_select(filter_options(assigns), @diff_filter)}
          </select>
        </form>
      </div>

      <div :if={!@selected and @diff_view == "list" and @hosts != []} class="overflow-x-auto">
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
            <.check_age :if={!host.disabled} check={@checks[host.id]} />
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
              title="Check this host (reads it over SSH)"
              aria-label="Check this host (reads it over SSH)"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
            <button
              id={"sync-row-#{host.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="sync-row"
              phx-value-id={host.id}
              disabled={host.disabled || @syncing}
              data-confirm={SyncConfirm.host(host, @statuses[host.id])}
              title="Sync this host"
              aria-label="Sync this host"
            >
              <.icon name="hero-cloud-arrow-up" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <ul
        :if={!@selected and @diff_view == "cards"}
        id="diff-hosts"
        class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
      >
        <li :for={host <- card_rows(assigns)}>
          <button
            id={"diff-host-#{host.id}"}
            class={[
              "flex w-full items-center justify-between gap-2 rounded-box bg-base-200 px-4 py-3",
              "text-left transition hover:bg-base-300"
            ]}
            phx-click="select"
            phx-value-id={host.id}
          >
            <span class="min-w-0">
              <span class="block truncate font-medium">{host.name}</span>
              <span class="block truncate text-xs opacity-60">{host.address}:{host.port}</span>
              <.check_age :if={!host.disabled} check={@checks[host.id]} />
            </span>
            <.status_badge status={@statuses[host.id]} />
          </button>
        </li>
      </ul>

      <section :if={@selected} id="diff-detail" class="card bg-base-200">
        <div class="card-body">
          <div class="flex items-center justify-between gap-4">
            <div>
              <h2 class="card-title text-base">
                {@selected.name}
                <.status_badge status={@statuses[@selected.id]} />
              </h2>
              <p class="text-xs opacity-60">{@selected.address}:{@selected.port}</p>
              <.check_age
                :if={!@selected.disabled}
                id="diff-detail-age"
                check={@checks[@selected.id]}
              />
            </div>
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
                /> Read again
              </button>
              <button
                id="sync-host"
                class="btn btn-primary btn-sm"
                phx-click="sync"
                disabled={@selected.disabled || @syncing || @detail_loading}
                data-confirm={SyncConfirm.host(@selected, @statuses[@selected.id])}
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

          <div
            :if={@detail && @detail.read_error}
            class="alert alert-error text-sm"
            id="diff-detail-read-error"
          >
            <.icon name="hero-exclamation-triangle" class="size-4" />
            Could not read the host's authorized_keys — the list below is incomplete: {@detail.read_error}
          </div>

          <div :if={@detail_loading && !@detail} class="flex items-center gap-3 text-sm opacity-70">
            <span class="loading loading-spinner loading-sm" aria-hidden="true"></span>
            Reading the host over SSH… a host that does not answer takes up to the SSH timeout.
            <button
              id="cancel-read"
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="cancel-read"
            >
              Cancel
            </button>
          </div>

          <div :for={login <- (@detail && @detail.logins) || []} class="space-y-1">
            <div class="flex items-center gap-2 pt-2">
              <.icon name="hero-user-circle" class="size-4 opacity-70" />
              <span class="font-mono text-sm font-medium">{login.login}</span>
              <span :if={login.has_pragma} class="badge badge-ghost badge-xs">managed</span>
              <span :if={login.readonly_condition} class="badge badge-error badge-xs">
                readonly: {login.readonly_condition}
              </span>
              <span :if={login.readonly_ignored} class="badge badge-warning badge-xs">
                ignored: {login.readonly_ignored}
              </span>
              <span :if={login.unsafe} class="badge badge-warning badge-xs">{login.unsafe}</span>
              <span :if={login.blocked} class="badge badge-error badge-xs">{login.blocked}</span>
              <button
                :if={@keyfiles[login.login]}
                id={"copy-keyfile-#{login.login}"}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-hook="CopyToClipboard"
                data-copy={@keyfiles[login.login]}
                title={"Copy the authorized_keys a sync would write for #{login.login}"}
                aria-label={"Copy the authorized_keys a sync would write for #{login.login}"}
              >
                <.icon name="hero-clipboard-document" class="size-4 [[data-copied]_&]:hidden" />
                <.icon
                  name="hero-check"
                  class="hidden size-4 text-success [[data-copied]_&]:inline-block"
                /> Copy authorized_keys
              </button>
              <button
                :if={
                  login.home_state == "unknown_login" and @current_user.role == "admin" and
                    not @selected.disabled and not @syncing
                }
                id={"remove-login-#{login.login}"}
                type="button"
                class="btn btn-ghost btn-xs text-error"
                phx-click="remove-login"
                phx-value-login={login.login}
                data-confirm={remove_login_confirm(@selected, login.login, @host_auths)}
                title={"Delete #{login.login}'s authorizations on this host and stop managing it"}
                aria-label={"Delete #{login.login}'s authorizations on this host and stop managing it"}
              >
                <.icon name="hero-user-minus" class="size-4" /> Remove login from host
              </button>
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
                <code
                  id={"key-line-#{login.login}-#{index}"}
                  class="min-w-0 truncate font-mono text-xs"
                  title={item.line}
                >
                  {short_key_line(item.line)}
                </code>
                <.key_owner
                  key={line_key(item.line, @key_owners)}
                  auth={owner_auth(line_key(item.line, @key_owners), login.login, @host_auths)}
                  login={login.login}
                  index={index}
                />
                <button
                  id={"copy-line-#{login.login}-#{index}"}
                  type="button"
                  class="btn btn-ghost btn-xs flex-none"
                  phx-hook="CopyToClipboard"
                  data-copy={item.line}
                  title="Copy the full key line"
                  aria-label="Copy the full key line"
                >
                  <.icon name="hero-clipboard" class="size-4 [[data-copied]_&]:hidden" />
                  <.icon
                    name="hero-check"
                    class="hidden size-4 text-success [[data-copied]_&]:inline-block"
                  />
                </button>
                <span
                  :if={item.note}
                  class="badge badge-ghost badge-sm shrink-0 whitespace-nowrap"
                >
                  {item.note}
                </span>
                <button
                  :if={
                    item.status != :extra_on_host and not @syncing and
                      revocable?(
                        owner_auth(line_key(item.line, @key_owners), login.login, @host_auths)
                      )
                  }
                  id={"revoke-#{login.login}-#{index}"}
                  class="btn btn-ghost btn-xs ml-auto flex-none text-error"
                  phx-click="remove-user-open"
                  phx-value-id={
                    owner_auth(line_key(item.line, @key_owners), login.login, @host_auths).id
                  }
                  title="Remove this SSH user's access to this login (shows every key it holds here)"
                  aria-label="Remove this SSH user's access to this login (shows every key it holds here)"
                >
                  <.icon name="hero-user-minus" class="size-4" />
                  Remove {line_key(item.line, @key_owners).user.username}
                </button>
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

      <.modal
        :if={@remove_user}
        id="remove-user-modal"
        on_cancel={JS.push("remove-user-cancel")}
      >
        <:title>Remove {@remove_user.username} from {@remove_user.login}</:title>

        <p class="mb-2 text-sm opacity-70">
          The marked keys belong to {@remove_user.username} and leave
          <span class="font-mono">{@remove_user.login}</span>
          on {@selected && @selected.name} at the next Sync (nothing is written now).
        </p>

        <ul id="remove-user-lines" class="mb-3 space-y-1">
          <li
            :for={
              {item, index} <-
                Enum.with_index(login_items(@detail, @remove_user.login))
            }
            id={"remove-user-line-#{index}"}
            class={[
              "flex items-center gap-2 rounded px-2 py-1 text-xs",
              if(owned_by?(item.line, @key_owners, @remove_user.user_id),
                do: "bg-error/20 text-error font-semibold remove-marked",
                else: "bg-base-200 opacity-60"
              )
            ]}
          >
            <.icon
              :if={owned_by?(item.line, @key_owners, @remove_user.user_id)}
              name="hero-minus-circle"
              class="size-4 flex-none"
            />
            <code class="min-w-0 truncate font-mono" title={item.line}>
              {short_key_line(item.line)}
            </code>
          </li>
        </ul>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="remove-user-cancel">
            Cancel
          </button>
          <button
            id="remove-user-confirm"
            type="button"
            class="btn btn-error"
            phx-click="remove-user-confirm"
          >
            Remove
          </button>
        </div>
      </.modal>

      <.modal :if={@unknown_key} id="unknown-key-modal" on_cancel={JS.push("unknown-key-cancel")}>
        <:title>Assign unknown key</:title>

        <p class="mb-2 text-sm opacity-70">
          This key is not in the database. Assign it to a user; the user is also
          granted login <span class="font-mono">{@unknown_key.login}</span>
          on this host if missing. The host itself is only changed by a later sync.
        </p>

        <div class="mb-2 flex items-center gap-2 rounded bg-base-300 p-2">
          <code class="min-w-0 truncate font-mono text-xs" title={@unknown_key.line}>
            {short_key_line(@unknown_key.line)}
          </code>
          <.copy_text id="copy-unknown-key" text={@unknown_key.line} class="ml-auto" />
        </div>

        <form
          id="unknown-key-form"
          phx-change="unknown-key-change"
          phx-submit="unknown-key-assign"
          class="space-y-2"
        >
          <.input
            type="select"
            name="assign[user_id]"
            value={@unknown_key.user_id}
            label="Assign to user"
            options={[{"Create user", "new"} | Enum.map(@unknown_key.users, &{&1.username, &1.id})]}
            required
          />
          <.input
            :if={@unknown_key.user_id == "new"}
            type="text"
            name="assign[username]"
            value={@unknown_key.username}
            label="New user name"
            required
          />
          <.input
            type="text"
            name="assign[key_name]"
            value={@unknown_key.key_name}
            label="Key name"
          />
          <p :if={@unknown_key.error} id="unknown-key-error" class="text-sm text-error">
            {@unknown_key.error}
          </p>

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

  attr :key, :any, required: true
  attr :auth, :any, required: true
  attr :login, :string, required: true
  attr :index, :integer, required: true

  # who a line belongs to: links to the SSH user's keys and to the grant
  defp key_owner(%{key: %UserKey{}} = assigns) do
    ~H"""
    <span class="flex flex-none items-center gap-1 text-xs opacity-80">
      <.link
        id={"owner-#{@login}-#{@index}"}
        navigate={~p"/keys?user_id=#{@key.user_id}"}
        class="link link-hover"
        title={"Keys of #{@key.user.username}"}
        aria-label={"Keys of #{@key.user.username}"}
      >
        {@key.user.username}
      </.link>
      <span :if={@key.name} class="opacity-60">· {@key.name}</span>
      <.link
        :if={@auth && @auth.grant_id}
        id={"grant-#{@login}-#{@index}"}
        navigate={~p"/grants?user_id=#{@key.user_id}"}
        class="badge badge-ghost badge-xs"
        title="This access comes from a grant"
        aria-label="This access comes from a grant"
      >
        grant
      </.link>
    </span>
    """
  end

  defp key_owner(assigns), do: ~H""

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
      aria-label={"Authorize #{elem(@info, 1).username} for #{@login} (database only)"}
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
      aria-label="Key is unknown — assign it to a user"
    >
      <.icon name="hero-user-plus" class="size-4" /> Add key…
    </button>
    """
  end

  defp extra_key_actions(assigns), do: ~H""
end
