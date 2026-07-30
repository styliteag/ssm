defmodule Ssm.Diffs.StatusCache do
  @moduledoc """
  Last known per-host sync status, ETS-backed and app-wide. The React app
  kept results in browser state, so revisiting the page felt instant; the
  LiveView equivalent keeps them server-side. The diff viewer shows cached
  results immediately on mount and re-checks only missing or stale hosts.
  """

  use GenServer

  @table :ssm_diff_status_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "All cached statuses: `%{host_id => {status, cached_at_ms}}`."
  @spec all() :: %{integer() => {term(), integer()}}
  def all do
    @table
    |> :ets.tab2list()
    |> Map.new()
  end

  @spec put(integer(), term()) :: :ok
  def put(host_id, status) do
    :ets.insert(@table, {host_id, {status, System.monotonic_time(:millisecond)}})
    :ok
  end

  @spec delete(integer()) :: :ok
  def delete(host_id) do
    :ets.delete(@table, host_id)
    :ok
  end

  @doc "Empty the cache (tests)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end
end
