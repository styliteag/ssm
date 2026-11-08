defmodule Ssm.Grants.Expansion do
  @moduledoc """
  Expands grants into `authorization` rows (`grant_id` set) — ADR-0012 §5.

  `reconcile/2` is a full, idempotent per-host reconcile: for each host it
  computes the wanted `(user, login)` pairs from all grants that reach the
  host (target customer or group, narrowed by the grant's scope lists) and
  makes the host's grant rows match:

    * a manual row (`grant_id` nil) for the same `(user, host, login)` wins
      and is kept; no second row is created (unique constraint);
    * a missing row is inserted through the normal path, so its login is
      recorded in `managed_logins`;
    * a row whose grant no longer reaches the host is deleted, and the host
      is marked "revocation pending" (`Ssm.Diffs.Revocations`) until a sync
      succeeds there;
    * a row of a grant that is going away, but that another grant still
      covers, is handed over to that grant (lowest id wins).

  It runs inside the transaction of its trigger (`Ssm.Grants.transaction/1`,
  `BEGIN IMMEDIATE`). Every add, remove and hand-over is audited with the
  trigger, the `grant_id`, the actor, the contract `job_id` when the trigger
  runs in a contract job, and the request id (`x-request-id`, also for
  contract calls that run before their job exists).

  `drift/0` compares without writing (`Ssm.Grants.DriftCheck` logs it).
  """

  import Ecto.Query

  alias Ssm.Activity
  alias Ssm.Authorizations
  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs.Revocations
  alias Ssm.Grants.Grant
  alias Ssm.Hosts.Host
  alias Ssm.Repo

  @type ctx :: %{
          optional(:trigger) => String.t(),
          optional(:actor) => String.t(),
          optional(:job_id) => term(),
          optional(:exclude) => [integer()]
        }
  @type counts :: %{
          added: non_neg_integer(),
          removed: non_neg_integer(),
          moved: non_neg_integer()
        }

  @zero %{added: 0, removed: 0, moved: 0}

  @doc """
  Reconcile the grant rows of `host_ids` (missing hosts are skipped).
  `ctx.exclude` lists grant ids to treat as gone (a grant or its target is
  about to be deleted). Opens an IMMEDIATE transaction unless one is open.
  """
  @spec reconcile([integer()], ctx()) :: {:ok, counts()} | {:error, term()}
  def reconcile(host_ids, ctx) do
    Ssm.Grants.transaction(fn ->
      grants = load_grants(Map.get(ctx, :exclude, []))

      host_ids
      |> Enum.uniq()
      |> Enum.reduce(@zero, fn id, acc ->
        Map.merge(acc, reconcile_host(id, grants, ctx), fn _k, a, b -> a + b end)
      end)
    end)
  end

  @doc """
  Before a host is deleted: audit its grant rows as removed (`host_delete`).
  The rows go with the host (`ON DELETE CASCADE`); nothing is marked, the
  host is gone from ssm.
  """
  @spec forget_host(integer(), ctx()) :: :ok
  def forget_host(host_id, ctx) do
    from(a in Authorization,
      where: a.host_id == ^host_id and not is_nil(a.grant_id),
      preload: [:user, :host]
    )
    |> Repo.all()
    |> Enum.each(&audit(ctx, "host_delete", "grant_remove", &1, %{grant_id: &1.grant_id}))
  end

  @doc "Ids of the hosts a grant targets plus the hosts holding its rows."
  @spec affected_host_ids([Grant.t()]) :: [integer()]
  def affected_host_ids(grants) do
    ids = Enum.map(grants, & &1.id)
    customers = for g <- grants, g.customer_id, do: g.customer_id
    groups = for g <- grants, g.group_id, do: g.group_id

    Repo.all(from a in Authorization, where: a.grant_id in ^ids, select: a.host_id) ++
      Repo.all(from h in Host, where: h.customer_id in ^customers, select: h.id) ++
      Repo.all(
        from hg in "host_groups",
          where: hg.group_id in ^groups,
          select: type(hg.host_id, :integer)
      )
  end

  @doc """
  Hosts whose grant rows differ from the grants (nothing is changed):
  `[%{host_id, host, missing: [...], stray: [...], moved: [...]}]`.
  """
  @spec drift() :: [map()]
  def drift do
    grants = load_grants([])
    groups = host_group_map()

    rows =
      Repo.all(
        from a in Authorization, select: map(a, [:id, :user_id, :host_id, :login, :grant_id])
      )

    rows_by_host = Enum.group_by(rows, & &1.host_id)

    from(h in Host, select: {h.id, h.name, h.customer_id}, order_by: h.id)
    |> Repo.all()
    |> Enum.flat_map(fn {id, name, customer_id} ->
      wanted = wanted(grants, customer_id, Map.get(groups, id, []))
      drift_entry(id, name, plan(wanted, Map.get(rows_by_host, id, [])))
    end)
  end

  defp drift_entry(_id, _name, %{add: [], remove: [], move: []}), do: []

  defp drift_entry(id, name, plan) do
    [
      %{
        host_id: id,
        host: name,
        missing:
          Enum.map(plan.add, fn {{u, l}, g} -> %{user_id: u, login: l, grant_id: g.id} end),
        stray: Enum.map(plan.remove, &Map.take(&1, [:id, :user_id, :login, :grant_id])),
        moved:
          Enum.map(plan.move, fn {row, g} ->
            %{id: row.id, grant_id: row.grant_id, wanted: g.id}
          end)
      }
    ]
  end

  ## Per host

  defp reconcile_host(host_id, grants, ctx) do
    case Repo.one(from h in Host, where: h.id == ^host_id, select: {h.id, h.customer_id}) do
      nil ->
        @zero

      {_id, customer_id} ->
        apply_plan(host_id, wanted(grants, customer_id, group_ids(host_id)), ctx)
    end
  end

  defp apply_plan(host_id, wanted, ctx) do
    rows =
      Repo.all(from a in Authorization, where: a.host_id == ^host_id, preload: [:user, :host])

    plan = plan(wanted, rows)
    trigger = Map.get(ctx, :trigger, "reconcile")

    Enum.each(plan.remove, fn row ->
      Repo.delete!(row)
      audit(ctx, trigger, "grant_remove", row, %{grant_id: row.grant_id})
    end)

    Enum.each(plan.move, fn {row, grant} ->
      Repo.update_all(from(a in Authorization, where: a.id == ^row.id), set: [grant_id: grant.id])

      audit(ctx, trigger, "grant_move", row, %{
        grant_id: grant.id,
        previous_grant_id: row.grant_id
      })
    end)

    Enum.each(plan.add, fn {{user_id, login}, grant} ->
      row = insert_row!(host_id, user_id, login, grant)
      audit(ctx, trigger, "grant_add", Repo.preload(row, [:user, :host]), %{grant_id: grant.id})
    end)

    if plan.remove != [], do: Revocations.mark(host_id, "grant reconcile (#{trigger})")

    %{added: length(plan.add), removed: length(plan.remove), moved: length(plan.move)}
  end

  defp insert_row!(host_id, user_id, login, grant) do
    attrs = %{host_id: host_id, user_id: user_id, login: login, comment: grant.comment}

    case %Authorization{grant_id: grant.id} |> Authorization.changeset(attrs) |> Repo.insert() do
      {:ok, row} ->
        :ok = Authorizations.record_managed_login(host_id, login)
        row

      {:error, changeset} ->
        Repo.rollback({:grant_expansion, changeset})
    end
  end

  # wanted: %{{user_id, login} => grant} (lowest grant id wins)
  # rows: the host's authorization rows (manual and grant-made)
  defp plan(wanted, rows) do
    {manual, made} = Enum.split_with(rows, &is_nil(&1.grant_id))
    manual_keys = MapSet.new(manual, &{&1.user_id, &1.login})
    made_by_key = Map.new(made, &{{&1.user_id, &1.login}, &1})

    %{
      remove: Enum.reject(made, &Map.has_key?(wanted, {&1.user_id, &1.login})),
      move:
        for(
          {key, grant} <- wanted,
          row = made_by_key[key],
          row && row.grant_id != grant.id,
          do: {row, grant}
        ),
      add:
        wanted
        |> Enum.reject(fn {key, _g} ->
          MapSet.member?(manual_keys, key) or Map.has_key?(made_by_key, key)
        end)
        |> Enum.sort()
    }
  end

  defp wanted(grants, customer_id, group_ids) do
    grants
    |> Enum.filter(&reaches?(&1, customer_id, group_ids))
    |> Enum.reduce(%{}, fn g, acc -> Map.put_new(acc, {g.ssh_user_id, g.login}, g) end)
  end

  @doc false
  # The grant's target matches the host, and the host is inside the
  # creator's scope lists (nil = all; a host without customer or group is
  # inside only for nil, like Ssm.Scope).
  def reaches?(%Grant{} = g, customer_id, group_ids) do
    target? =
      (not is_nil(g.customer_id) and g.customer_id == customer_id) or
        (not is_nil(g.group_id) and g.group_id in group_ids)

    target? and
      (is_nil(g.scope_customer_ids) or
         (not is_nil(customer_id) and customer_id in g.scope_customer_ids)) and
      (is_nil(g.scope_group_ids) or Enum.any?(group_ids, &(&1 in g.scope_group_ids)))
  end

  defp load_grants(exclude),
    do: Repo.all(from g in Grant, where: g.id not in ^exclude, order_by: g.id)

  defp group_ids(host_id) do
    Repo.all(
      from hg in "host_groups",
        where: hg.host_id == ^host_id,
        select: type(hg.group_id, :integer)
    )
  end

  defp host_group_map do
    from(hg in "host_groups", select: {type(hg.host_id, :integer), type(hg.group_id, :integer)})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp audit(ctx, trigger, action, row, details) do
    Activity.log(%{
      activity_type: "auth",
      action: action,
      target: "#{row.user && row.user.username}@#{row.host && row.host.name}:#{row.login}",
      host_id: row.host_id,
      user_id: if(action == "grant_remove", do: nil, else: row.user_id),
      actor_username: Map.get(ctx, :actor) || Ssm.Grants.actor() || "ssm",
      details:
        Map.merge(
          %{
            trigger: trigger,
            job_id: Map.get(ctx, :job_id),
            request_id: Logger.metadata()[:request_id]
          },
          details
        )
    })
  end
end
