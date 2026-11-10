defmodule SsmWeb.HostsLive do
  @moduledoc """
  Hosts page: list with online/offline badges, status filter pills,
  create/edit modal, enable/disable, delete, an async SSH connection test,
  and cross-links (authorization count → authorizations page, diff link per
  host) — the React HostsPage. Every SSH action checks `host.disabled`
  first (non-negotiable rule #4).

  The badge is `Ssm.HostStatus`: derived from the status cache, else the
  stored key check (so it survives a restart), overlaid by this page's own
  connection tests. Read keys or a passed test is "online"; a refused key
  ("auth failed") and a changed host key are named, any other failure is
  "offline". Rows are a plain assign, not a stream — filtering and status
  overlays must re-render rows.

  "Test connections" runs the same connection test for every enabled host the
  current filter lists (after a confirm), `SSH_CONCURRENCY` at a time, and
  each result lands in its row as it arrives. A connection test is not a
  key check, so it is not written to `host_checks`; the row shows "checked
  … ago" from the stored key check, or "checked just now" after a test.

  Admins open a host's "Managed logins" (`Ssm.Hosts.ManagedLogins`) and
  forget a login without authorizations and without a file on the host;
  the role is checked in every event, not only by hiding the button.
  """

  use SsmWeb, :live_view

  alias Ssm.Activity.Entries
  alias Ssm.Authorizations
  alias Ssm.Diffs.HostChecks
  alias Ssm.Diffs.StatusCache
  alias Ssm.Hosts
  alias Ssm.HostStatus
  alias Ssm.Hosts.Host
  alias Ssm.Hosts.ManagedLogins
  alias Ssm.Hosts.PinState
  alias Ssm.Scope
  alias SsmWeb.ErrorText
  alias SsmWeb.Layouts
  alias SsmWeb.StatusText

  @filters ~w(active all online offline unknown disabled pending)
  @jump_host_locked "Read-only: this host is the jump host of other hosts, " <>
                      "so only an account that sees all hosts may change it."
  @outside_scope "Not available: your account is limited to some customers or host groups, " <>
                   "and this would act outside your scope."

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Hosts")
     |> assign(form: nil, editing: nil, testing_id: nil, pinning: false)
     |> assign(filter: "active", q: nil, conn_results: %{}, sort: nil, view: "list")
     |> assign(limit: @page_size, page_size: @page_size, shown: [])
     |> assign(:refilter_queued, false)
     |> assign(refreshing: false, refresh_done: 0, refresh_total: 0, refresh_ids: [])
     |> assign(:tested_at, %{})
     |> assign(:managed, nil)
     |> reload_hosts()}
  end

  # filter pill and search live in the URL (?filter=…&q=…), see SsmWeb.Links
  @impl true
  def handle_params(params, _uri, socket) do
    filter = if params["filter"] in @filters, do: params["filter"], else: "active"

    {:noreply,
     socket
     |> assign(
       filter: filter,
       q: params["q"],
       sort: parse_sort(params["sort"]),
       limit: @page_size
     )
     |> refilter()}
  end

  @sort_keys ~w(name address login jump access status)

  # ?sort=key:asc|desc; anything else is no sort
  defp parse_sort(value) when is_binary(value) do
    case String.split(value, ":") do
      [key, "asc"] when key in @sort_keys -> {key, :asc}
      [key, "desc"] when key in @sort_keys -> {key, :desc}
      _ -> nil
    end
  end

  defp parse_sort(_), do: nil

  defp sort_param({key, dir}), do: "#{key}:#{dir}"
  defp sort_param(nil), do: nil

  defp patch_query(socket, changes) do
    params =
      %{
        "filter" => socket.assigns.filter,
        "q" => socket.assigns.q,
        "sort" => sort_param(socket.assigns.sort)
      }
      |> Map.merge(changes)
      |> query_params(~w(filter q sort))
      |> Map.reject(fn {k, v} -> k == "filter" and v == "active" end)

    push_patch(socket, to: ~p"/hosts?#{params}")
  end

  # Everything host-bearing is read through the user's scope (ADR-0012).
  defp scope(socket), do: Scope.of(socket.assigns.current_user)

  defp reload_hosts(socket) do
    scope = scope(socket)
    hosts = Hosts.list_hosts(scope)

    socket
    |> assign(:global, Scope.global?(scope))
    |> assign(:admin, socket.assigns.current_user.role == "admin")
    |> assign(:all_hosts, hosts)
    |> assign(:host_names, Map.new(hosts, &{&1.id, &1.name}))
    |> assign(:stored_checks, HostChecks.stored(scope))
    |> assign(:pending_revocations, Ssm.Diffs.Revocations.pending(scope))
    |> assign(
      :auth_counts,
      Enum.frequencies_by(Authorizations.list_authorizations(scope, []), & &1.host_id)
    )
    |> refilter()
  end

  defp refilter(socket) do
    %{all_hosts: hosts, conn_results: tests, filter: filter, stored_checks: stored} =
      socket.assigns

    cached = StatusCache.all()
    statuses = Map.new(hosts, &{&1.id, host_status(&1, tests[&1.id], cached, stored)})

    pending = socket.assigns.pending_revocations

    rows =
      hosts
      |> Enum.filter(&matches_filter?(filter, &1, statuses[&1.id], pending))
      |> Enum.filter(&matches?(socket.assigns.q, [&1.name, &1.address, &1.comment, &1.username]))
      |> SsmWeb.TableSort.sort(socket.assigns.sort, host_sorters(socket.assigns, statuses))

    socket
    |> assign(:statuses, statuses)
    |> assign(:rows, rows)
    |> assign(:shown, Enum.take(rows, socket.assigns.limit))
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

  defp status_rank(status) do
    cond do
      HostStatus.reachable?(status) -> 0
      HostStatus.error?(status) -> 1
      status == :unchecked -> 2
      true -> 3
    end
  end

  # disabled beats everything; a connection test on this page beats the
  # last key check (cache, else stored row); no signal is "unknown".
  defp host_status(%Host{} = host, nil, cached, stored),
    do: HostStatus.derive(host, cached[host.id], stored[host.id])

  defp host_status(%Host{disabled: true}, _tested, _cached, _stored), do: :disabled
  defp host_status(_host, tested, _cached, _stored), do: tested

  # `pending`: the revocation-pending marks (`Revocations.pending/1`)
  defp matches_filter?("active", host, _status, _pending), do: not host.disabled
  defp matches_filter?("all", _host, _status, _pending), do: true
  defp matches_filter?("online", _host, status, _pending), do: HostStatus.reachable?(status)
  defp matches_filter?("offline", _host, status, _pending), do: HostStatus.error?(status)
  defp matches_filter?("unknown", _host, status, _pending), do: status == :unchecked
  defp matches_filter?("disabled", _host, status, _pending), do: status == :disabled
  defp matches_filter?("pending", host, _status, pending), do: Map.has_key?(pending, host.id)

  defp pill_count(hosts, statuses, pending, filter) do
    Enum.count(hosts, &matches_filter?(filter, &1, statuses[&1.id], pending))
  end

  ## Events

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) when filter in @filters do
    {:noreply, patch_query(socket, %{"filter" => filter})}
  end

  def handle_event("search", params, socket) do
    {:noreply, patch_query(socket, %{"q" => params["q"]})}
  end

  def handle_event("more", _params, socket),
    do: {:noreply, socket |> assign(:limit, socket.assigns.limit + @page_size) |> refilter()}

  def handle_event("sort", %{"key" => key}, socket) do
    sort = SsmWeb.TableSort.toggle(socket.assigns.sort, key)
    {:noreply, patch_query(socket, %{"sort" => sort_param(sort)})}
  end

  def handle_event("view-mode", %{"view" => view}, socket) when view in ~w(list cards) do
    {:noreply, assign(socket, :view, view)}
  end

  # A host created here has no customer or group, so it would be outside a
  # scoped user's own scope; hosts reach them through Mission Control.
  def handle_event("new", _params, %{assigns: %{global: false}} = socket),
    do: {:noreply, put_flash(socket, :error, @outside_scope)}

  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       # connection user root and port 22 — the overwhelmingly common case
       form: to_form(Hosts.change_host(%Host{}, %{"username" => "root", "port" => "22"})),
       editing: nil,
       jump_candidates: Hosts.jump_candidates(scope(socket), nil)
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Hosts.get_host(scope(socket), parse_id(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      host ->
        if Hosts.editable?(scope(socket), host) do
          {:noreply,
           assign(socket,
             form: to_form(Hosts.change_host(host)),
             editing: host,
             jump_candidates: Hosts.jump_candidates(scope(socket), host)
           )}
        else
          {:noreply, put_flash(socket, :error, @jump_host_locked)}
        end
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

  def handle_event("save", _params, %{assigns: %{editing: nil, global: false}} = socket),
    do: {:noreply, put_flash(socket, :error, @outside_scope)}

  def handle_event("save", %{"host" => params}, socket) do
    params = params |> normalize_params() |> jump_via_for(socket)

    result =
      case socket.assigns.editing do
        nil -> Hosts.create_host(params)
        host -> update_in_scope(socket, host, params)
      end

    case result do
      {:ok, host} ->
        action = if socket.assigns.editing, do: :update, else: :create
        log_host_activity(socket, action, host)

        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Host #{host.name} #{action}d.")
         |> reload_hosts()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply,
         socket |> assign(form: nil, editing: nil) |> put_flash(:error, host_error(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Host{} = host <- Hosts.get_host(scope(socket), parse_id(id)),
         {:ok, _} <- Hosts.delete_host(scope(socket), host) do
      log_host_activity(socket, :delete, host)

      {:noreply,
       socket
       |> put_flash(:info, "Host #{host.name} deleted.")
       |> reload_hosts()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      {:error, reason} when is_atom(reason) or is_tuple(reason) ->
        {:noreply, put_flash(socket, :error, host_error(reason))}

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
    with %Host{} = host <- Hosts.get_host(scope(socket), parse_id(id)),
         {:ok, updated} <- Hosts.update_host(scope(socket), host, %{disabled: !host.disabled}) do
      action = if updated.disabled, do: :disable, else: :enable
      log_host_activity(socket, action, updated)

      # the host's status was forgotten (Ssm.HostStatus); so is its test here
      {:noreply,
       socket
       |> update(:conn_results, &Map.delete(&1, updated.id))
       |> update(:tested_at, &Map.delete(&1, updated.id))
       |> put_flash(:info, "Host #{updated.name} #{action}d.")
       |> reload_hosts()}
    else
      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, host_error(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Host not found.")}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    case Hosts.get_host(scope(socket), parse_id(id)) do
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

  def handle_event("refresh_all", _params, %{assigns: %{refreshing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("refresh_all", _params, socket) do
    # re-read through the scope: the listed rows may be stale
    in_scope = socket |> scope() |> Hosts.list_hosts() |> MapSet.new(& &1.id)

    case socket.assigns.rows
         |> Enum.filter(&MapSet.member?(in_scope, &1.id))
         |> refresh_targets() do
      [] ->
        {:noreply, put_flash(socket, :error, "No enabled host to refresh in this list.")}

      targets ->
        {:noreply,
         socket
         |> assign(refreshing: true, refresh_done: 0, refresh_total: length(targets))
         |> assign(:refresh_ids, Enum.map(targets, &elem(&1, 0)))
         |> start_refresh(targets)}
    end
  end

  # Managed logins: admins only, checked here (the button is hidden too).
  def handle_event("managed-logins", _params, %{assigns: %{admin: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "Managed logins are for admins only.")}

  def handle_event("managed-logins", %{"id" => id}, socket) do
    case Hosts.get_host(scope(socket), parse_id(id)) do
      nil -> {:noreply, put_flash(socket, :error, "Host not found.")}
      host -> {:noreply, open_managed(socket, host)}
    end
  end

  def handle_event("managed-logins-close", _params, socket),
    do: {:noreply, assign(socket, :managed, nil)}

  def handle_event("forget-login", _params, %{assigns: %{admin: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "Managed logins are for admins only.")}

  def handle_event("forget-login", %{"host-id" => id, "login" => login}, socket)
      when is_binary(login) do
    case Hosts.get_host(scope(socket), parse_id(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Host not found.")}

      host ->
        actor = socket.assigns.current_user.actor

        {:noreply,
         socket
         |> update(:managed, &(&1 && %{&1 | busy: true}))
         |> start_async(:forget_login, fn ->
           {host, login, ManagedLogins.forget(host, login, actor)}
         end)}
    end
  end

  # Pins every enabled host, so only for users who see every host.
  def handle_event("pin_host_keys", _params, %{assigns: %{global: false}} = socket),
    do: {:noreply, put_flash(socket, :error, @outside_scope)}

  def handle_event("pin_host_keys", _params, socket) do
    actor = socket.assigns.current_user.actor

    {:noreply,
     socket
     |> assign(:pinning, true)
     |> start_async(:pin_host_keys, fn -> Hosts.pin_host_keys_now(actor: actor) end)}
  end

  # each host's result is shown the moment it is known (the diff page's
  # streaming pattern), not after the whole batch
  @impl true
  def handle_info({:refresh_result, host_id, result}, socket) do
    {:noreply,
     socket
     |> update(:refresh_done, &(&1 + 1))
     |> update(:tested_at, &Map.put(&1, host_id, DateTime.utc_now()))
     |> update(:conn_results, &Map.put(&1, host_id, result))
     |> queue_refilter()}
  end

  def handle_info(:refilter, socket),
    do: {:noreply, socket |> assign(:refilter_queued, false) |> refilter()}

  # Results of "Test connections" arrive one per host; the results already
  # waiting are taken in first, then the list is rebuilt once (refilter reads
  # the whole status cache and sorts), not once per host.
  defp queue_refilter(%{assigns: %{refilter_queued: true}} = socket), do: socket

  defp queue_refilter(socket) do
    send(self(), :refilter)
    assign(socket, :refilter_queued, true)
  end

  @impl true
  def handle_async(:refresh_all, {:ok, :done}, socket) do
    {online, offline} = refresh_counts(socket)

    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> refilter()
     |> put_flash(
       # some unreachable hosts are a normal fleet state, not an error
       if(online == 0 and offline > 0, do: :error, else: :info),
       "Tested #{online + offline} hosts: #{online} online, #{offline} unreachable."
     )}
  end

  def handle_async(:refresh_all, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> put_flash(:error, ErrorText.crashed("Testing connections", reason))}
  end

  def handle_async(:pin_host_keys, {:ok, report}, socket) do
    {:noreply,
     socket
     |> assign(:pinning, false)
     |> put_flash(if(report.failed == [], do: :info, else: :error), pin_summary(report))
     |> reload_hosts()}
  end

  def handle_async(:pin_host_keys, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:pinning, false)
     |> put_flash(:error, ErrorText.crashed("Pinning host keys", reason))}
  end

  def handle_async(:test_connection, {:ok, {host, result}}, socket) do
    socket =
      socket
      |> assign(:testing_id, nil)
      |> update(:tested_at, &Map.put(&1, host.id, DateTime.utc_now()))

    socket = put_conn_result(socket, host.id, HostStatus.from_connection(result))

    case socket.assigns.conn_results[host.id] do
      :reachable ->
        {:noreply, put_flash(socket, :info, "Connection to #{host.name} succeeded.")}

      {_tag, message} ->
        {:noreply, put_flash(socket, :error, "Connection to #{host.name} failed: #{message}")}
    end
  end

  def handle_async(:forget_login, {:ok, {host, login, result}}, socket) do
    socket = update(socket, :managed, &(&1 && %{&1 | busy: false}))

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Forgot login #{login} on #{host.name}.")
         |> open_managed(host)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Login #{login} kept: #{forget_error(reason)}")}
    end
  end

  def handle_async(:forget_login, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> update(:managed, &(&1 && %{&1 | busy: false}))
     |> put_flash(:error, ErrorText.crashed("Forgetting the login", reason))}
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:testing_id, nil)
     |> put_flash(:error, ErrorText.crashed("The connection test", reason))}
  end

  defp access_entries(1), do: "1 access entry"
  defp access_entries(n), do: "#{n} access entries"

  # Deleting a host only forgets it: ssm never connects again, so whatever
  # it placed there (the authorized key lines, its own key) stays.
  defp delete_confirm(host, 0),
    do:
      "Delete host #{host.name}? ssm never connects to it again; ssm's own key stays on the host until someone removes it there."

  defp delete_confirm(host, count) do
    entries = if count == 1, do: "1 authorization goes", else: "#{count} authorizations go"

    "Delete host #{host.name}? Its #{entries} with it, but ssm never connects to it again: " <>
      "the key lines it placed and ssm's own key stay on the host. " <>
      "To take access away, delete the authorizations and sync first, then delete the host."
  end

  defp open_managed(socket, host),
    do: assign(socket, :managed, %{host: host, logins: ManagedLogins.list(host.id), busy: false})

  defp forget_error(:managed_login_not_found), do: "it is not managed (any more)."
  defp forget_error({_tag, message}) when is_binary(message), do: message
  defp forget_error(reason), do: ErrorText.reason(reason)

  defp put_conn_result(socket, host_id, result) do
    socket
    |> update(:conn_results, &Map.put(&1, host_id, result))
    |> refilter()
  end

  ## Test connections (all listed hosts)

  # every enabled host the current filter lists; disabled hosts are never
  # contacted (rule #4), whatever the filter shows
  defp refresh_targets(rows) do
    rows
    |> Enum.reject(& &1.disabled)
    |> Enum.map(&{&1.id, Hosts.target_for(&1)})
  end

  defp start_refresh(socket, targets) do
    parent = self()
    concurrency = check_concurrency()

    start_async(socket, :refresh_all, fn ->
      targets
      |> Task.async_stream(
        fn {id, target} ->
          send(parent, {:refresh_result, id, HostStatus.from_connection(Ssm.Ssh.connect(target))})
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      :done
    end)
  end

  # SSH_CONCURRENCY (default 32), as the diff page's checks
  defp check_concurrency do
    Application.get_env(:ssm, :ssh, [])
    |> Keyword.get(:check_concurrency, 32)
  end

  defp refresh_counts(%{assigns: %{refresh_ids: ids, conn_results: results}}) do
    ids
    |> Enum.map(&results[&1])
    |> Enum.reduce({0, 0}, fn status, {on, off} ->
      cond do
        status == :reachable -> {on + 1, off}
        HostStatus.error?(status) -> {on, off + 1}
        true -> {on, off}
      end
    end)
  end

  defp refreshable_count(rows), do: Enum.count(rows, &(not &1.disabled))

  # "checked … ago": a test on this page wins over the stored key check
  defp checked_label(host_id, tested_at, stored) do
    case {tested_at[host_id], stored[host_id]} do
      {%DateTime{}, _} -> "checked just now"
      {nil, %{checked_at: %DateTime{} = at}} -> "checked #{ago(at)}"
      _ -> "never checked"
    end
  end

  defp ago(at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  ## Helpers

  defp pin_summary(%{pinned: pinned, already: already, failed: failed}) do
    base =
      "Pinned #{length(pinned)} host key(s); #{length(already)} already pinned."

    case failed do
      [] ->
        base

      _ ->
        {shown, rest} = Enum.split(failed, 3)

        details =
          Enum.map_join(shown, "; ", fn {name, reason} -> "#{name}: #{pin_error(reason)}" end)

        more = if rest == [], do: "", else: "; and #{length(rest)} more (filter Unreachable)"

        base <> " Failed (still unpinned or changed): " <> details <> more
    end
  end

  defp pin_error({:host_key_changed, %{pinned: pinned, offered: offered}}),
    do: "host key changed (pinned #{pinned}, offered #{offered.fingerprint})"

  defp pin_error({_code, message}) when is_binary(message), do: message
  defp pin_error(reason), do: ErrorText.reason(reason)

  # A cleared select posts `""`; Ecto's cast treats `""` as a missing value
  # rather than an explicit nil, so map it here (the jump_via pattern).
  defp normalize_params(params) do
    Map.update(params, "jump_via", nil, fn
      "" -> nil
      value -> value
    end)
  end

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  # Jump hosts are global objects (ADR-0012 §3): only an admin sets or
  # changes `jump_via`; for everyone else the field keeps its stored value.
  defp jump_via_for(params, %{assigns: %{admin: true}}), do: params
  defp jump_via_for(params, _socket), do: Map.delete(params, "jump_via")

  # Re-read through the scope (`Hosts.update_host/3`): the host may have left
  # it since the form opened; a scoped user's connection fields are dropped.
  defp update_in_scope(socket, host, params), do: Hosts.update_host(scope(socket), host, params)

  defp host_error(:not_found), do: "Host not found."
  defp host_error(:jump_host), do: @jump_host_locked

  defp host_error({:jump_host_in_use, names}),
    do: "Cannot delete this host: it is the jump host of #{Enum.join(names, ", ")}."

  defp log_host_activity(socket, action, host),
    do: Entries.host(action, host, socket.assigns.current_user.actor)

  defp status_title(:disabled), do: "Disabled — all SSH operations blocked"
  defp status_title(:unchecked), do: "Not checked yet — run the diff viewer or a connection test"
  defp status_title({:auth_failed, message}), do: "The host refused ssm's key: #{message}"

  defp status_title({:host_key_changed, message}),
    do: "The host presented a different host key than the pinned one: #{message}"

  defp status_title({:unreachable, message}), do: message
  defp status_title(_reachable), do: "Reachable (last key check or connection test)"

  # Host-key pin: unpinned / pre-seeded (not confirmed) / confirmed.
  attr :host, Host, required: true

  defp pin_icon(assigns) do
    assigns = assign(assigns, :state, PinState.of(assigns.host))

    ~H"""
    <span
      data-pin-state={@state}
      data-pinned={@state != :unpinned}
      title={PinState.title(@host)}
    >
      <.icon name={pin_icon_name(@state)} class={["size-3.5", pin_icon_class(@state)]} />
    </span>
    """
  end

  defp pin_icon_name(:unpinned), do: "hero-lock-open"
  defp pin_icon_name(_pinned), do: "hero-finger-print"

  defp pin_icon_class(:unpinned), do: "text-warning"
  defp pin_icon_class(:preseeded), do: "opacity-30"
  defp pin_icon_class(:confirmed), do: "opacity-60"

  # Non-root login: reduced functionality, explained in the tooltip.
  attr :host, Host, required: true

  defp limited_badge(assigns) do
    ~H"""
    <span
      :if={Hosts.limited?(@host)}
      data-limited
      class="badge badge-warning badge-xs align-middle"
      title={Hosts.limited_reason(@host)}
    >
      limited
    </span>
    """
  end

  # ADR-0012 §6: a grant reconcile removed access here; the keys stay on the
  # host until a sync succeeds.
  attr :pending, :any, default: nil
  attr :host, Host, required: true

  defp revocation_badge(assigns) do
    ~H"""
    <.link
      :if={@pending}
      id={"revocation-pending-#{@host.id}"}
      navigate={~p"/diff?host_id=#{@host.id}"}
      class="badge badge-warning badge-sm whitespace-nowrap align-middle"
      title={"Pending sync (#{@pending.reason}, #{ago(@pending.inserted_at)}): access was removed in ssm; the keys stay on the host until a sync, or a read that finds nothing revoked left"}
      aria-label={"Pending sync (#{@pending.reason}, #{ago(@pending.inserted_at)}): access was removed in ssm; the keys stay on the host until a sync, or a read that finds nothing revoked left"}
    >
      pending sync · {ago(@pending.inserted_at)}
    </.link>
    """
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:hosts}
    >
      <.header>
        Hosts
        <:subtitle>{@host_count} managed SSH hosts</:subtitle>
        <:actions>
          <.button
            id="refresh-all"
            phx-click="refresh_all"
            disabled={@refreshing or refreshable_count(@rows) == 0}
            data-confirm={"Refresh #{refreshable_count(@rows)} hosts? ssm connects to each over SSH and reads nothing but the connection/host key — nothing is written."}
            title="Test the SSH connection of every enabled host in this list"
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @refreshing && "motion-safe:animate-spin"]}
            />
            <%= if @refreshing do %>
              Refreshing {@refresh_done}/{@refresh_total}
            <% else %>
              Test connections ({refreshable_count(@rows)})
            <% end %>
          </.button>
          <.button
            :if={@global}
            id="pin-host-keys"
            phx-click="pin_host_keys"
            disabled={@pinning}
            data-confirm="Connect to every enabled host without a pinned SSH host key and trust the key it presents now (trust on first use)?"
            title="Pin SSH host keys of all enabled hosts that are not pinned yet"
          >
            <.icon
              name={if @pinning, do: "hero-arrow-path", else: "hero-finger-print"}
              class={["size-4", @pinning && "motion-safe:animate-spin"]}
            /> Pin host keys
          </.button>
          <.button :if={@global} id="new-host" variant="primary" phx-click="new">
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
              {"offline", "Unreachable"},
              {"unknown", "Not checked"},
              {"disabled", "Disabled"},
              {"pending", "Pending sync"}
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
          {label} ({pill_count(@all_hosts, @statuses, @pending_revocations, filter)})
        </button>
      </div>

      <.list_search id="hosts-search" q={@q} placeholder="Search name, address, comment" />

      <div
        :if={@host_count == 0}
        id="hosts-empty"
        class="rounded-box border border-dashed border-base-300 p-6 text-center text-sm"
      >
        <p class="opacity-70">
          {if @global,
            do: "No hosts yet. Add the first host ssm should manage.",
            else: "No hosts in your scope yet."}
        </p>
        <.button :if={@global} variant="primary" class="mt-3" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New host
        </.button>
      </div>

      <.view_toggle id="hosts-view" view={@view} />

      <p :if={@host_count > 0 and @rows == []} class="text-sm opacity-60">
        No hosts match this filter.
      </p>

      <ul :if={@view == "cards" and @rows != []} class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <li
          :for={host <- @shown}
          id={"host-card-#{host.id}"}
          class="rounded-box bg-base-200 px-4 py-3"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="min-w-0">
              <.host_link id={host.id} name={host.name} class="block truncate font-medium" />
              <span class="block truncate text-xs opacity-60">{host.address}:{host.port}</span>
            </span>
            <span
              class={["badge badge-sm flex-none", StatusText.connection_class(@statuses[host.id])]}
              title={status_title(@statuses[host.id])}
            >
              {StatusText.connection(@statuses[host.id])}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs opacity-70">
            <span>login {host.username}</span>
            <.limited_badge host={host} />
            <.revocation_badge host={host} pending={@pending_revocations[host.id]} />
            <span :if={host.jump_via}>via {Map.get(@host_names, host.jump_via)}</span>
            <span :if={not host.disabled} id={"card-checked-#{host.id}"}>
              {checked_label(host.id, @tested_at, @stored_checks)}
            </span>
            <.link
              navigate={~p"/authorizations?host_id=#{host.id}"}
              class="link link-hover"
              title="Authorizations on this host"
              aria-label="Authorizations on this host"
            >
              {access_entries(Map.get(@auth_counts, host.id, 0))}
            </.link>
          </div>
          <p :if={host.comment} class="mt-1 truncate text-xs opacity-60">{host.comment}</p>
          <div class="mt-2 flex gap-1">
            <.host_actions
              host={host}
              testing_id={@testing_id}
              admin={@admin}
              auth_count={Map.get(@auth_counts, host.id, 0)}
            />
          </div>
        </li>
      </ul>

      <div :if={length(@rows) > @page_size} class="flex items-center gap-3 text-sm">
        <span id="hosts-position" class="opacity-70">{length(@shown)} of {length(@rows)}</span>
        <.button :if={length(@shown) < length(@rows)} id="hosts-more" phx-click="more">
          Show {min(@page_size, length(@rows) - length(@shown))} more
        </.button>
      </div>

      <div :if={@view == "list" and @rows != []} class="overflow-x-auto">
        <.table
          id="hosts"
          rows={@shown}
          sort={@sort}
          row_id={&"hosts-#{&1.id}"}
          row_item={&Function.identity/1}
        >
          <:col :let={host} label="Name" sort="name">
            <.host_link id={host.id} name={host.name} class="font-medium" />
            <.pin_icon host={host} />
            <p :if={host.comment} class="text-xs opacity-60">{host.comment}</p>
          </:col>
          <:col :let={host} label="Address" sort="address">{host.address}:{host.port}</:col>
          <:col :let={host} label="Connection user" sort="login">
            {host.username} <.limited_badge host={host} />
          </:col>
          <:col :let={host} label="Jump via" sort="jump">
            {(host.jump_via && Map.get(@host_names, host.jump_via)) || "—"}
          </:col>
          <:col :let={host} label="Access" sort="access">
            <.link
              navigate={~p"/authorizations?host_id=#{host.id}"}
              class="link link-hover tabular-nums"
              title="Authorizations on this host"
              aria-label="Authorizations on this host"
            >
              {Map.get(@auth_counts, host.id, 0)}
            </.link>
          </:col>
          <:col :let={host} label="Status" sort="status">
            <.link
              navigate={host_path(host.id)}
              class={["badge badge-sm", StatusText.connection_class(@statuses[host.id])]}
              title={status_title(@statuses[host.id])}
              aria-label={status_title(@statuses[host.id])}
            >
              {StatusText.connection(@statuses[host.id])}
            </.link>
            <.revocation_badge host={host} pending={@pending_revocations[host.id]} />
            <p :if={not host.disabled} id={"checked-#{host.id}"} class="text-xs opacity-60">
              {checked_label(host.id, @tested_at, @stored_checks)}
            </p>
          </:col>
          <:action :let={host}>
            <.host_actions
              host={host}
              testing_id={@testing_id}
              admin={@admin}
              auth_count={Map.get(@auth_counts, host.id, 0)}
            />
          </:action>
        </.table>
      </div>

      <SsmWeb.ManagedLoginsComponents.managed_logins_modal :if={@managed} managed={@managed} />

      <.modal :if={@form} id="host-modal" on_cancel={JS.push("cancel")}>
        <:title>{if @editing, do: "Edit host", else: "New host"}</:title>
        <.host_modal_body
          form={@form}
          editing={@editing}
          jump_candidates={@jump_candidates}
          admin={@admin}
          global={@global}
        />
      </.modal>
    </Layouts.app>
    """
  end

  attr :host, :any, required: true
  attr :testing_id, :any, required: true
  attr :admin, :boolean, default: false
  attr :auth_count, :integer, default: 0

  defp host_actions(assigns) do
    ~H"""
    <.link
      id={"diff-link-#{@host.id}"}
      navigate={~p"/diff?host_id=#{@host.id}"}
      class="btn btn-ghost btn-xs"
      title="Open in Sync"
      aria-label="Open in Sync"
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
      aria-label="Test SSH connection"
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
    <details
      id={"host-menu-#{@host.id}"}
      class="dropdown dropdown-end"
      data-popover
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary
        class="btn btn-ghost btn-xs list-none"
        title="More actions"
        aria-label={"More actions for #{@host.name}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-4" />
      </summary>
      <ul class="menu dropdown-content z-30 w-52 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg">
        <li :if={@admin}>
          <button
            id={"managed-logins-#{@host.id}"}
            phx-click={menu_click("managed-logins", @host)}
          >
            <.icon name="hero-user-group" class="size-4" /> Managed logins (admin)
          </button>
        </li>
        <li>
          <button id={"edit-host-#{@host.id}"} phx-click={menu_click("edit", @host)}>
            <.icon name="hero-pencil-square" class="size-4" /> Edit host
          </button>
        </li>
        <li>
          <button id={"toggle-host-#{@host.id}"} phx-click={menu_click("toggle_disabled", @host)}>
            <.icon
              name={if @host.disabled, do: "hero-power", else: "hero-no-symbol"}
              class="size-4"
            />
            {if @host.disabled, do: "Enable host", else: "Disable host"}
          </button>
        </li>
        <li>
          <button
            id={"delete-host-#{@host.id}"}
            class="text-error"
            phx-click={menu_click("delete", @host)}
            data-confirm={delete_confirm(@host, @auth_count)}
          >
            <.icon name="hero-trash" class="size-4" /> Delete host
          </button>
        </li>
      </ul>
    </details>
    """
  end

  # a menu entry: push the event for the host and close its menu
  defp menu_click(event, host) do
    event
    |> JS.push(value: %{id: host.id})
    |> JS.remove_attribute("open", to: "#host-menu-#{host.id}")
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :jump_candidates, :list, required: true
  attr :admin, :boolean, required: true
  attr :global, :boolean, required: true

  defp host_modal_body(assigns) do
    ~H"""
    <div>
      <.form for={@form} id="host-form" phx-change="validate" phx-submit="save" class="space-y-2">
        <.input field={@form[:name]} type="text" label="Name" required />
        <div class="grid grid-cols-3 gap-3">
          <div class="col-span-2">
            <.input
              field={@form[:address]}
              type="text"
              label="Address"
              required
              readonly={!@global}
            />
          </div>
          <.input field={@form[:port]} type="number" label="Port" required readonly={!@global} />
        </div>
        <.input
          field={@form[:username]}
          type="text"
          label="Connection user (ssm logs in as)"
          required
          readonly={!@global}
        />
        <p :if={!@global} id="host-form-connection-hint" class="-mt-1 text-xs opacity-70">
          Address, port and login user are set by an account that sees all hosts.
        </p>
        <p
          :if={@form[:username].value not in [nil, "", "root"]}
          id="host-form-limited-hint"
          class="-mt-1 text-xs opacity-70"
        >
          Not root: ssm will only see and manage the authorized_keys files this user can access.
        </p>
        <.input
          field={@form[:jump_via]}
          searchable
          type="select"
          label="Jump via"
          prompt="None (direct connection)"
          options={Enum.map(@jump_candidates, &{&1.name, &1.id})}
          disabled={!@admin}
        />
        <p :if={!@admin} id="host-form-jump-hint" class="-mt-1 text-xs opacity-70">
          Jump hosts are set by an admin.
        </p>
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
