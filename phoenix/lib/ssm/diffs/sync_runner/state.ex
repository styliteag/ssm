defmodule Ssm.Diffs.SyncRunner.State do
  @moduledoc """
  The per-host state of a manual sync (`Ssm.Diffs.SyncRunner`), pure:
  `%{host_id => run}`. A host absent from the map is idle; a present one is
  running for that run. idle → running(run) only through `claim/3`, which
  never takes a running host; running(run) → idle only through `release/3`
  by that same run, or `release_run/2` when the run ends or crashes.
  """

  @type run :: term()
  @type t :: %{optional(integer()) => run()}

  @doc """
  Claim the idle hosts among `host_ids` for `run`. Returns
  `{claimed, busy, state}` — `busy` are the hosts some run already holds
  (also `run` itself); a host listed twice counts once.
  """
  @spec claim(t(), [integer()], run()) :: {[integer()], [integer()], t()}
  def claim(state, host_ids, run) do
    {claimed, busy} = host_ids |> Enum.uniq() |> Enum.split_with(&(not Map.has_key?(state, &1)))
    {claimed, busy, Map.merge(state, Map.new(claimed, &{&1, run}))}
  end

  @doc "Free `host_id` — only when `run` holds it."
  @spec release(t(), integer(), run()) :: t()
  def release(state, host_id, run) do
    case state do
      %{^host_id => ^run} -> Map.delete(state, host_id)
      _ -> state
    end
  end

  @doc "Free every host `run` still holds."
  @spec release_run(t(), run()) :: t()
  def release_run(state, run), do: state |> Enum.reject(fn {_, r} -> r == run end) |> Map.new()

  @doc "`:idle` or `{:running, run}`."
  @spec status(t(), integer()) :: :idle | {:running, run()}
  def status(state, host_id) do
    case state do
      %{^host_id => run} -> {:running, run}
      _ -> :idle
    end
  end
end
