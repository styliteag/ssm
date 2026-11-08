defmodule Ssm.Diffs.HostChecks do
  @moduledoc """
  The persisted periodic key check (US-API-08): runs the diff of a host,
  stores the result in `host_checks` (`Ssm.Diffs.HostCheck`) and feeds the
  diff page's `Ssm.Diffs.StatusCache`; `sweep/1` does that for every enabled
  host with bounded concurrency; `page_summaries/3` reads the results back
  for the mctl host summaries.

  Every SSH access goes through `Ssm.Diffs.host_diff/2`, which refuses
  disabled hosts before connecting and honours the readonly markers. A
  disabled host keeps no row (its summary is `unknown`).
  """

  import Ecto.Query

  alias Ssm.Diffs
  alias Ssm.Diffs.{HostCheck, StatusCache, SyncCheck}
  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Users

  require Logger

  @default_concurrency 8
  @timeout_slack_seconds 30

  @doc """
  Check one host and store the result. Options: `:client` (default
  `Ssm.Ssh`), `:owners` (key base64 → user name; loaded when absent),
  `:now` (tests). Returns `{:ok, %HostCheck{}}`, `{:error, :disabled}` or
  `{:error, :not_found}`.
  """
  @spec check_host(integer(), keyword()) ::
          {:ok, HostCheck.t()} | {:error, :disabled | :not_found}
  def check_host(host_id, opts \\ []) do
    client = Keyword.get(opts, :client, Ssm.Ssh)

    case Diffs.host_diff(client, host_id) do
      {:ok, diff} ->
        record(host_id, diff, opts)

      {:error, {:host_disabled, _}} ->
        forget(host_id)
        {:error, :disabled}

      {:error, :not_found} ->
        forget(host_id)
        {:error, :not_found}
    end
  end

  @doc """
  Store a diff that was already read (e.g. the diff page's detail view of
  one host) as that host's check, without a second SSH connection. Options
  as `check_host/2` (`:owners`, `:now`). `{:ok, %HostCheck{}}` or
  `{:error, :not_found}` when the host was deleted meanwhile.
  """
  @spec record(integer(), Diffs.HostDiff.t(), keyword()) ::
          {:ok, HostCheck.t()} | {:error, :not_found}
  def record(host_id, %Diffs.HostDiff{} = diff, opts \\ []) do
    owners = Keyword.get_lazy(opts, :owners, &owners/0)
    StatusCache.put(host_id, SyncCheck.status(diff))
    store(host_id, SyncCheck.result(diff, owners), now(opts))
  end

  @doc """
  The stored check of every host in `scope` (default all) that has one:
  host id → `%HostCheck{}`.
  """
  @spec stored(Ssm.Scope.t()) :: %{integer() => HostCheck.t()}
  def stored(%Ssm.Scope{} = scope \\ Ssm.Scope.global()),
    do: HostCheck |> Ssm.Scope.filter(scope) |> Repo.all() |> Map.new(&{&1.host_id, &1})

  @doc """
  The ssm users owning each key (key base64 → user name), for `:owners`.
  Load it once when checking many hosts.
  """
  @spec owners() :: %{String.t() => String.t()}
  def owners do
    Map.new(Users.list_keys(), &{&1.key_base64, &1.user.username})
  end

  @doc """
  Check every enabled host with at most `:concurrency` checks at once
  (default `SSM_SYNC_CONCURRENCY`, 8). A check that crashes or runs past
  `:timeout` (ms; default SSH timeout plus 30 s) counts as failed and never
  stops the sweep. Options for tests: `:check_fun` (`fn host_id -> {:ok, _}
  | {:error, _}`), `:client`.
  """
  @spec sweep(keyword()) :: %{checked: non_neg_integer(), failed: non_neg_integer()}
  def sweep(opts \\ []) do
    ids = Repo.all(from h in Host, where: h.disabled == false, order_by: h.id, select: h.id)
    check = Keyword.get_lazy(opts, :check_fun, fn -> default_check(opts) end)

    outcomes =
      Task.Supervisor.async_stream_nolink(
        Ssm.Diffs.TaskSupervisor,
        ids,
        fn id -> safely(check, id) end,
        max_concurrency: Keyword.get(opts, :concurrency, concurrency()),
        timeout: Keyword.get(opts, :timeout, timeout_ms()),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {:ok, _}} -> :checked
        _other -> :failed
      end)

    %{
      checked: Enum.count(outcomes, &(&1 == :checked)),
      failed: Enum.count(outcomes, &(&1 == :failed))
    }
  end

  defp default_check(opts) do
    shared = [owners: owners()] ++ Keyword.take(opts, [:client])
    fn id -> check_host(id, shared) end
  end

  defp safely(check, id) do
    check.(id)
  rescue
    e ->
      Logger.warning("host check #{id} crashed: #{Exception.message(e)}")
      {:error, :crashed}
  catch
    kind, reason ->
      Logger.warning("host check #{id} #{kind}: #{inspect(reason)}")
      {:error, :crashed}
  end

  @doc """
  A keyset page of `%{id, disabled, updated_at, check}` (the host and its
  stored result or nil), by host id. Filters: `:host_id`, `:changed_after`
  (host edit or new result after the time). `{rows, next_id | nil}`.
  """
  @spec page_summaries(integer() | nil, pos_integer(), map()) :: {[map()], integer() | nil}
  def page_summaries(after_id, limit, filters) do
    rows =
      base()
      |> filter_host_id(Map.get(filters, :host_id))
      |> filter_changed_after(Map.get(filters, :changed_after))
      |> after_id(after_id)
      |> order_by([h], asc: h.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    case Enum.split(rows, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, List.last(page).id}
    end
  end

  @doc "One host with its stored result, or nil."
  @spec get_summary_row(integer()) :: map() | nil
  def get_summary_row(host_id), do: base() |> where([h], h.id == ^host_id) |> Repo.one()

  defp base do
    from h in Host,
      left_join: c in HostCheck,
      on: c.host_id == h.id,
      select: %{id: h.id, disabled: h.disabled, updated_at: h.updated_at, check: c}
  end

  defp filter_host_id(query, nil), do: query
  defp filter_host_id(query, id), do: where(query, [h], h.id == ^id)

  defp filter_changed_after(query, nil), do: query

  defp filter_changed_after(query, %DateTime{} = at) do
    at = DateTime.truncate(at, :second)
    where(query, [h, c], h.updated_at > ^at or c.changed_at > ^at)
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [h], h.id > ^id)

  ## Storing

  defp store(host_id, result, now) do
    previous = Repo.get(HostCheck, host_id)

    row = %HostCheck{
      host_id: host_id,
      state: result.state,
      logins: result.logins,
      drift: result.drift,
      error_code: result.error_code,
      error: result.error,
      checked_at: now,
      changed_at: if(same?(previous, result), do: previous.changed_at, else: now)
    }

    {:ok,
     Repo.insert!(row,
       on_conflict: {:replace_all_except, [:host_id]},
       conflict_target: :host_id
     )}
  rescue
    # the host was deleted while its check ran
    Ecto.ConstraintError -> {:error, :not_found}
  end

  defp same?(nil, _result), do: false

  defp same?(%HostCheck{} = row, result) do
    row.state == result.state and row.logins == result.logins and row.drift == result.drift and
      row.error_code == result.error_code
  end

  defp forget(host_id) do
    Repo.delete_all(from c in HostCheck, where: c.host_id == ^host_id)
    :ok
  end

  defp now(opts),
    do: Keyword.get_lazy(opts, :now, fn -> DateTime.truncate(DateTime.utc_now(), :second) end)

  defp concurrency, do: config(:concurrency, @default_concurrency)

  defp timeout_ms do
    ssh = Application.get_env(:ssm, :ssh, [])
    (Keyword.get(ssh, :timeout_seconds, 120) + @timeout_slack_seconds) * 1000
  end

  defp config(key, default),
    do: Application.get_env(:ssm, :sync_check, []) |> Keyword.get(key, default)
end
