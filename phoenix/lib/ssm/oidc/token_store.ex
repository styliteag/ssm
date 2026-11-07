defmodule Ssm.OIDC.TokenStore do
  @moduledoc """
  Server-side keeper of raw ID tokens too large for the session cookie
  (they are only ever used as `id_token_hint` at logout). ETS, single node,
  lost on restart (the hint is then simply left out). Entries are addressed
  by a random reference that goes into the session, live for the OIDC session
  maximum and are deleted at logout. Tokens are never logged.
  """

  use GenServer

  @table :ssm_oidc_id_tokens

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Keep `token` for `ttl_seconds`; returns the random reference."
  @spec put(String.t(), non_neg_integer()) :: String.t()
  def put(token, ttl_seconds) when is_binary(token) do
    ref = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    :ets.insert(@table, {ref, token, now() + ttl_seconds * 1000})
    ref
  end

  @doc "The token for `ref`, or `nil` when unknown or expired."
  @spec get(term()) :: String.t() | nil
  def get(ref) when is_binary(ref) do
    case :ets.lookup(@table, ref) do
      [{^ref, token, expires}] -> if expires > now(), do: token
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def get(_ref), do: nil

  @spec delete(term()) :: :ok
  def delete(ref) when is_binary(ref) do
    :ets.delete(@table, ref)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(_ref), do: :ok

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, :timer.minutes(1))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    Process.send_after(self(), :sweep, :timer.minutes(1))
    {:noreply, state}
  end
end
