defmodule Ssm.OIDC.JtiStore do
  @moduledoc """
  Replay store for back-channel logout tokens: a `jti` is accepted once per
  `ttl` (10 minutes). ETS, single node; lost on restart, which is fine
  because logout tokens are only accepted when `iat` is under 5 minutes old.
  """

  use GenServer

  @table :ssm_oidc_jti
  @ttl_ms :timer.minutes(10)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`:ok` the first time a `jti` is seen within the ttl, `:replay` after."
  @spec claim(String.t()) :: :ok | :replay
  def claim(jti) when is_binary(jti) do
    now = System.monotonic_time(:millisecond)

    case :ets.insert_new(@table, {jti, now + @ttl_ms}) do
      true -> :ok
      false -> reclaim(jti, now)
    end
  end

  defp reclaim(jti, now) do
    case :ets.lookup(@table, jti) do
      [{^jti, expires}] when expires <= now ->
        :ets.insert(@table, {jti, now + @ttl_ms})
        :ok

      _ ->
        :replay
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, :timer.minutes(1))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, :timer.minutes(1))
    {:noreply, state}
  end
end
