defmodule MctlContract.Jobs.Ecto do
  @moduledoc """
  Optional job store (table `mctl_jobs`) for providers whose tool has no
  job concept of its own. States: `queued → running → succeeded | failed`.

  `run/4` creates a job and runs the work in a task:

      Jobs.Ecto.run("create_host", host_id, fn job_id ->
        Jobs.Ecto.progress(job_id, "activating")
        {:ok, %{}}            # or {:error, code, message}
      end)

  An exception in the work fails the job with `internal_error`. Jobs that
  were running when the node stopped stay `running`; `fail_stale/1`
  marks them failed at boot.
  """
  import Ecto.Query
  require Logger

  alias MctlContract.Jobs.Job

  @doc "Creates a queued job."
  @spec create(String.t(), String.t() | nil) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create(kind, host_id) do
    %Job{kind: kind, host_id: host_id, state: "queued", inserted_at: now()}
    |> repo().insert()
  end

  @doc """
  Creates a job and runs `fun.(job_id)` in a task (option
  `task_supervisor`, else an unlinked task). `fun` returns `{:ok, result}`
  or `{:error, code, message}`. Returns `{:ok, job}` at once.

  `inline: true` runs the work in the caller and returns the finished job
  (tests, tools without background workers).
  """
  def run(kind, host_id, fun, opts \\ []) do
    with {:ok, job} <- create(kind, host_id) do
      work = fn -> execute(job.id, fun) end

      cond do
        opts[:inline] ->
          work.()
          get(job.id)

        sup = opts[:task_supervisor] ->
          {:ok, _pid} = Task.Supervisor.start_child(sup, work)
          {:ok, job}

        true ->
          {:ok, _pid} = Task.start(work)
          {:ok, job}
      end
    end
  end

  defp execute(id, fun) do
    set(id, state: "running")

    case fun.(to_string(id)) do
      {:ok, result} -> succeed(id, result)
      {:error, code, message} -> fail(id, code, message)
    end
  rescue
    e ->
      Logger.error("mctl job #{id}: " <> Exception.format(:error, e, __STACKTRACE__))
      fail(id, "internal_error", "the job crashed")
  end

  @doc "Sets the progress text (and state running)."
  def progress(id, text), do: set(id, progress: text, state: "running")

  @doc "Marks the job succeeded with a result map."
  def succeed(id, result),
    do: set(id, state: "succeeded", result: Jason.encode!(result), finished_at: now())

  @doc "Marks the job failed."
  def fail(id, code, message) do
    error = Jason.encode!(%{code: code, message: message})
    set(id, state: "failed", error: error, finished_at: now())
  end

  @doc "Fails jobs left `queued` or `running` (call once at boot)."
  def fail_stale(message \\ "interrupted by a restart") do
    error = Jason.encode!(%{code: "interrupted", message: message})

    {n, _} =
      repo().update_all(from(j in Job, where: j.state in ["queued", "running"]),
        set: [state: "failed", error: error, finished_at: now()]
      )

    n
  end

  @doc """
  Deletes finished jobs (succeeded or failed) older than `days` (by
  `finished_at`) in batches (option `batch_size`, default 1000); returns
  the number deleted. Queued and running jobs stay.
  """
  def prune(days \\ 30, opts \\ []) do
    cutoff = DateTime.add(now(), -days * 86_400)
    batch = Keyword.get(opts, :batch_size, MctlContract.Prune.default_batch())

    query =
      from j in Job, where: j.state in ["succeeded", "failed"] and j.finished_at < ^cutoff

    MctlContract.Prune.delete_in_batches(repo(), Job, query, batch)
  end

  @doc "`{:ok, job}` or `{:error, :not_found}` (string id from the URL)."
  def get(id) when is_binary(id) do
    with {int, ""} <- Integer.parse(id),
         %Job{} = job <- repo().get(Job, int) do
      {:ok, job}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(id) when is_integer(id), do: get(Integer.to_string(id))

  @doc "A page of jobs by id (provider page semantics, key `[id]`)."
  def list(%{after: after_key, limit: limit, filters: filters}) do
    query =
      from(j in Job, order_by: [asc: j.id], limit: ^(limit + 1))
      |> after_id(after_key)
      |> filter(:host_id, filters["host_id"])
      |> filter(:state, filters["state"])

    {items, more} = query |> repo().all() |> Enum.split(limit)
    next = if more != [], do: [List.last(items).id]
    {:ok, items, next}
  end

  defp after_id(q, nil), do: q
  defp after_id(q, [id]) when is_integer(id), do: where(q, [j], j.id > ^id)

  defp after_id(q, [id]) when is_binary(id),
    do: after_id(q, [String.to_integer(id)])

  defp filter(q, _field, nil), do: q
  defp filter(q, field, value), do: where(q, [j], field(j, ^field) == ^value)

  @doc "The contract map of a job."
  def to_map(%Job{} = j) do
    %{
      id: to_string(j.id),
      kind: j.kind,
      state: j.state,
      host_id: j.host_id,
      progress: j.progress,
      result: decode(j.result),
      error: decode(j.error),
      created_at: j.inserted_at,
      finished_at: j.finished_at
    }
  end

  defp decode(nil), do: nil
  defp decode(json), do: Jason.decode!(json)

  defp set(id, changes) do
    case repo().get(Job, to_int(id)) do
      nil -> {:error, :not_found}
      job -> job |> Ecto.Changeset.change(changes) |> repo().update()
    end
  end

  defp to_int(id) when is_integer(id), do: id
  defp to_int(id) when is_binary(id), do: String.to_integer(id)

  defp now, do: DateTime.utc_now(:second)
  defp repo, do: MctlContract.Repo.get()
end
