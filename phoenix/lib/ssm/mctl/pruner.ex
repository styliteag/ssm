defmodule Ssm.Mctl.Pruner do
  @moduledoc """
  Periodic cleanup of the `mctl_contract` tables with the library's batched
  prunes: finished `mctl_jobs` older than 30 days, `mctl_idempotency` keys
  older than 24 hours. Runs every `interval` (default 1 hour); a failing run
  is logged and retried on the next tick.
  """

  use GenServer
  require Logger

  alias MctlContract.Idempotency.Ecto, as: Idempotency
  alias MctlContract.Jobs.Ecto, as: Jobs

  @job_days 30

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Prune once; returns how many rows went per table."
  @spec run() :: %{jobs: non_neg_integer(), idempotency: non_neg_integer()}
  def run do
    %{jobs: Jobs.prune(@job_days), idempotency: Idempotency.prune()}
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, :timer.hours(1))
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      result = run()

      if result.jobs + result.idempotency > 0,
        do:
          Logger.info(
            "mctl: pruned #{result.jobs} job(s), #{result.idempotency} idempotency key(s)"
          )
    rescue
      e -> Logger.warning("mctl: prune failed: #{Exception.message(e)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :prune, interval)
end
