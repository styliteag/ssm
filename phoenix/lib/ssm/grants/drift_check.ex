defmodule Ssm.Grants.DriftCheck do
  @moduledoc """
  The periodic grant reconciler (ADR-0012 §5): every interval (default 15
  minutes, `config :ssm, :grants_drift_check, interval_ms: …`; off with
  `false`, as in tests) it compares the grants with the `authorization`
  rows (`Ssm.Grants.Expansion.drift/0`) and logs every host whose grant
  rows differ. It never corrects: the triggers reconcile in their own
  transactions, so drift points at a bug or a hand edit of the database.

  A check that crashes is logged; the next tick runs normally.
  """

  use GenServer

  alias Ssm.Grants.Expansion

  require Logger

  @default_interval_ms 15 * 60 * 1000

  @doc "Compare once and log the drift; returns the drift list."
  @spec run() :: [map()]
  def run do
    drift = Expansion.drift()
    Enum.each(drift, &log/1)
    drift
  end

  defp log(%{host_id: id, host: name} = entry) do
    Logger.warning(
      "grant drift on host #{id} (#{name}): " <>
        "missing=#{inspect(entry.missing)} stray=#{inspect(entry.stray)} " <>
        "moved=#{inspect(entry.moved)}"
    )
  end

  @doc "Child spec options for the application, or nil when switched off."
  @spec child_opts() :: keyword() | nil
  def child_opts do
    case Application.get_env(:ssm, :grants_drift_check, []) do
      false ->
        nil

      opts when is_list(opts) ->
        [interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)]
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval_ms)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)

    try do
      run()
    rescue
      error -> Logger.warning("grant drift check failed: #{Exception.message(error)}")
    end

    {:noreply, state}
  end
end
