defmodule Ssm.Diffs.Revocations do
  @moduledoc """
  "Revocation pending" (ADR-0012 §6): a host whose `authorization` rows a
  grant reconcile removed is marked until a sync succeeds there. The keys
  stay on the host until then; a sync removes them (also for a login whose
  last row is gone, through `managed_logins`). The mark is shown on the
  Hosts page; it never triggers an SSH write by itself.

  `Ssm.Diffs.sync_host_reported/2` reads the mark before it reads any grant
  and clears exactly that mark after a fully successful sync.
  """

  import Ecto.Query

  alias Ssm.Diffs.{PendingRevocation, RevocationSync}
  alias Ssm.{Repo, Scope}

  @doc "Mark `host_id`; a new mark moves the time, so only a later sync clears it."
  @spec mark(integer(), String.t()) :: :ok
  def mark(host_id, reason) when is_integer(host_id) do
    Repo.insert_all(
      PendingRevocation,
      [%{host_id: host_id, reason: reason, inserted_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:reason, :inserted_at]},
      conflict_target: [:host_id]
    )

    # the removal-only sync (opt-in) starts after the commit
    if Repo.in_transaction?(),
      do: RevocationSync.collect(host_id),
      else: RevocationSync.request([host_id])
  end

  @doc """
  The mark of `host_id` as a sync sees it at its start (its time), or nil.
  Read before the sync reads any grant: the mark commits together with the
  row removals, so a sync that sees a mark also sees those removals.
  """
  @spec seen(integer()) :: DateTime.t() | nil
  def seen(host_id),
    do: Repo.one(from p in PendingRevocation, where: p.host_id == ^host_id, select: p.inserted_at)

  @doc """
  Clear exactly the mark `seen/1` returned. A newer mark (a removal
  committed while the sync ran) stays.
  """
  @spec clear(integer(), DateTime.t() | nil) :: :ok
  def clear(_host_id, nil), do: :ok

  def clear(host_id, %DateTime{} = seen) do
    Repo.delete_all(
      from p in PendingRevocation, where: p.host_id == ^host_id and p.inserted_at == ^seen
    )

    :ok
  end

  @spec pending?(integer()) :: boolean()
  def pending?(host_id),
    do: Repo.exists?(from p in PendingRevocation, where: p.host_id == ^host_id)

  @doc "Marked hosts in `scope`: `%{host_id => %PendingRevocation{}}`."
  @spec pending(Scope.t()) :: %{integer() => PendingRevocation.t()}
  def pending(%Scope{} = scope) do
    PendingRevocation
    |> Scope.filter(scope)
    |> Repo.all()
    |> Map.new(&{&1.host_id, &1})
  end
end
