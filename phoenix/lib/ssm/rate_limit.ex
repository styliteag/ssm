defmodule Ssm.RateLimit do
  @moduledoc """
  In-memory fixed-window counters (ETS) for request and failure limits —
  no dependency, single node (ssm runs one instance on SQLite).

  A counter is `{key, window}`: `hit/4` counts and checks in one step,
  `check/4` only reads, `count/3` only counts. Over the limit the answer is
  `{:error, retry_after}` with the seconds left in the current window.
  Expired windows are swept once a minute. Counters are lost on restart,
  which is acceptable for throttling.

  `opts[:now]` (unix seconds) exists for tests.
  """

  use GenServer

  @table :ssm_rate_limit
  @sweep_every :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Count one event for `key` and check it against `limit` per `window` seconds."
  @spec hit(term(), pos_integer(), pos_integer(), keyword()) :: :ok | {:error, pos_integer()}
  def hit(key, limit, window, opts \\ []) do
    now = now(opts)
    verdict(increment(key, window, now), limit, window, now)
  end

  @doc "Is `key` still under `limit` in the current window? Does not count."
  @spec check(term(), pos_integer(), pos_integer(), keyword()) :: :ok | {:error, pos_integer()}
  def check(key, limit, window, opts \\ []) do
    now = now(opts)

    case :ets.lookup(@table, {key, window_start(now, window)}) do
      [{_, count, _expires}] when count >= limit -> {:error, retry_after(now, window)}
      _ -> :ok
    end
  end

  @doc "Count one event for `key`; returns the count in the current window."
  @spec count(term(), pos_integer(), keyword()) :: pos_integer()
  def count(key, window, opts \\ []), do: increment(key, window, now(opts))

  @doc "Drop windows that ended at or before `now`; returns how many."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ System.system_time(:second)) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @doc """
  The counter key for a client address: IPv4 as is, IPv6 per /64 (one
  host or LAN usually owns a whole /64), IPv4-mapped IPv6 as its IPv4.
  """
  @spec client_key(:inet.ip_address()) :: String.t()
  def client_key({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  def client_key({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: client_key({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  def client_key({a, b, c, d, _, _, _, _}),
    do:
      "#{{a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string() |> String.trim_trailing("::")}::/64"

  @doc "Forget every window of `key`."
  @spec clear(term()) :: :ok
  def clear(key) do
    :ets.match_delete(@table, {{key, :_}, :_, :_})
    :ok
  end

  @doc "Forget every counter (tests)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp increment(key, window, now) do
    start = window_start(now, window)
    row_key = {key, start}
    :ets.update_counter(@table, row_key, {2, 1}, {row_key, 0, start + window})
  end

  defp verdict(count, limit, _window, _now) when count <= limit, do: :ok
  defp verdict(_count, _limit, window, now), do: {:error, retry_after(now, window)}

  defp window_start(now, window), do: now - rem(now, window)
  defp retry_after(now, window), do: window - rem(now, window)
  defp now(opts), do: Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
