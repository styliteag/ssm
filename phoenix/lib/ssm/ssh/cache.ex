defmodule Ssm.Ssh.Cache do
  @moduledoc """
  Per-host read cache in front of the real client — port of ssh/caching.py.
  Reading authorized_keys is the hot path; this memoises `read_file` per
  `{host_id, path}` in ETS and invalidates the entry whenever `write_file`
  hits the same path. `connect`/`exec` pass straight through.
  """

  @behaviour Ssm.Ssh.Client

  use GenServer

  @table :ssm_ssh_read_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  ## Ssm.Ssh.Client implementation (runs in the caller's process)

  @impl Ssm.Ssh.Client
  def connect(target), do: inner().connect(target)

  @impl Ssm.Ssh.Client
  def exec(target, command, opts), do: inner().exec(target, command, opts)

  @impl Ssm.Ssh.Client
  def read_file(target, path) do
    key = {target.host_id, path}

    case :ets.lookup(@table, key) do
      [{^key, file}] ->
        {:ok, file}

      [] ->
        with {:ok, file} <- inner().read_file(target, path) do
          :ets.insert(@table, {key, file})
          {:ok, file}
        end
    end
  end

  @impl Ssm.Ssh.Client
  def write_file(target, path, content) do
    result = inner().write_file(target, path, content)
    :ets.delete(@table, {target.host_id, path})
    result
  end

  @impl Ssm.Ssh.Client
  def close do
    :ets.delete_all_objects(@table)
    inner().close()
  end

  @doc "Drop every cache entry (tests; the cache runs in the app tree)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Empty the entire cache (used by tests between cases)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Drop cache entries for a host; with nil path, drop all of its entries."
  @spec invalidate(integer(), String.t() | nil) :: :ok
  def invalidate(host_id, path \\ nil)

  def invalidate(host_id, nil) do
    :ets.match_delete(@table, {{host_id, :_}, :_})
    :ok
  end

  def invalidate(host_id, path) do
    :ets.delete(@table, {host_id, path})
    :ok
  end

  defp inner, do: Application.get_env(:ssm, :ssh_inner_client, Ssm.Ssh.ErlangClient)
end
