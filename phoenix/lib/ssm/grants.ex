defmodule Ssm.Grants do
  @moduledoc """
  Grants: SSH access for an SSH user per customer or host group (ADR-0012
  §5, phase 2). A grant is expanded into normal `authorization` rows
  (`Ssm.Grants.Expansion`); diff, sync and the contract `people` read those
  rows unchanged.

  Who may create a grant (`create_grant/2`, actor = the web user's
  `current_user` map with `role`, `scope` and `actor`):

    * `admin`: any target; the grant is unrestricted;
    * `operator`: a target inside its scope (the customer, or the group, is
      listed or the dimension is `*`). The grant stores the operator's scope
      as id lists, so it reaches only hosts inside that scope, now and for
      future hosts (target ∩ creator scope);
    * anyone else (`viewer`): none.

  A scoped operator sees and deletes only grants whose reach lies inside its
  scope (`manageable?/2`); others act as missing.
  """

  import Ecto.Query

  alias Ssm.Activity
  alias Ssm.Customers.Customer
  alias Ssm.Diffs.RevocationSync
  alias Ssm.Grants.{Expansion, Grant}
  alias Ssm.Groups.Group
  alias Ssm.{Repo, Scope}

  @writers ~w(admin operator)

  @type actor :: %{role: String.t(), scope: Scope.t(), actor: String.t()}

  @doc """
  Run `fun` (or an `Ecto.Multi`) in a transaction that takes SQLite's write
  lock at BEGIN (`mode: :immediate`); inside an open transaction it joins
  that one (Ecto nesting). Returns what `Repo.transaction/2` returns.

  The outermost call hands the hosts marked "revocation pending" during the
  transaction to `Ssm.Diffs.RevocationSync` after a commit, and drops them
  after a rollback.
  """
  @spec transaction((-> term()) | Ecto.Multi.t()) :: term()
  def transaction(fun_or_multi) do
    if Repo.in_transaction?() do
      Repo.transaction(fun_or_multi, mode: :immediate)
    else
      try do
        result = Repo.transaction(fun_or_multi, mode: :immediate)
        if match?({:ok, _}, result), do: RevocationSync.flush()
        result
      after
        RevocationSync.discard()
      end
    end
  end

  @doc """
  The web or API user behind the current process (set by `SsmWeb.UserAuth`
  for LiveViews and by the `/api/v2` auth plug), used as the audit actor of
  reconciles that follow a manual change; nil elsewhere.
  """
  @spec put_actor(String.t() | nil) :: :ok
  def put_actor(actor) do
    Process.put({__MODULE__, :actor}, actor)
    :ok
  end

  @spec actor() :: String.t() | nil
  def actor, do: Process.get({__MODULE__, :actor})

  @doc "Grants visible to `scope` (`opts`: `:ssh_user_id`, `:customer_id`, `:group_id`)."
  @spec list_grants(Scope.t(), keyword()) :: [Grant.t()]
  def list_grants(%Scope{} = scope, opts \\ []) do
    ids = scope_ids(scope)

    opts
    |> Enum.reduce(from(g in Grant, order_by: g.id), fn
      {:ssh_user_id, id}, q when is_integer(id) -> where(q, [g], g.ssh_user_id == ^id)
      {:customer_id, id}, q when is_integer(id) -> where(q, [g], g.customer_id == ^id)
      {:group_id, id}, q when is_integer(id) -> where(q, [g], g.group_id == ^id)
      _other, q -> q
    end)
    |> preload([:ssh_user, :customer, :group])
    |> Repo.all()
    |> Enum.filter(&within?(ids, &1))
  end

  @doc "A grant visible to `scope`, or nil."
  @spec get_grant(Scope.t(), term()) :: Grant.t() | nil
  def get_grant(%Scope{} = scope, id) when is_integer(id) do
    case Repo.get(Grant, id) do
      nil ->
        nil

      grant ->
        if manageable?(scope, grant), do: Repo.preload(grant, [:ssh_user, :customer, :group])
    end
  end

  def get_grant(_scope, _id), do: nil

  @doc "Does the grant's reach lie inside `scope` in both dimensions?"
  @spec manageable?(Scope.t(), Grant.t()) :: boolean()
  def manageable?(%Scope{} = scope, %Grant{} = grant), do: within?(scope_ids(scope), grant)

  @doc "May this web user create or delete grants at all?"
  @spec writer?(map()) :: boolean()
  def writer?(%{role: role}), do: role in @writers
  def writer?(_actor), do: false

  @doc """
  Create a grant and expand it, in one IMMEDIATE transaction. `attrs`:
  `ssh_user_id`, `customer_id` or `group_id`, `login`, `comment`.
  """
  @spec create_grant(actor(), map()) ::
          {:ok, Grant.t()} | {:error, :forbidden | :out_of_scope | Ecto.Changeset.t() | term()}
  def create_grant(actor, attrs) do
    scope = Map.get(actor, :scope, Scope.none())
    ids = scope_ids(scope)

    internal = %{
      created_by: Map.get(actor, :actor),
      scope_customer_ids: list_or_nil(ids.customers),
      scope_group_ids: list_or_nil(ids.groups)
    }

    changeset = Grant.create_changeset(%Grant{}, attrs, internal)

    cond do
      not writer?(actor) -> {:error, :forbidden}
      not changeset.valid? -> {:error, changeset}
      # a scoped dimension whose slugs match no customer/group reaches nothing
      [] in [ids.customers, ids.groups] -> {:error, :out_of_scope}
      not target_in_scope?(ids, changeset) -> {:error, :out_of_scope}
      true -> insert_and_expand(changeset, actor)
    end
  end

  defp insert_and_expand(changeset, actor) do
    transaction(fn ->
      with {:ok, grant} <- Repo.insert(changeset),
           grant = Repo.preload(grant, [:ssh_user, :customer, :group]),
           {:ok, _counts} <-
             Expansion.reconcile(Expansion.affected_host_ids([grant]), ctx(actor, "grant_create")) do
        audit(actor, "grant_create", grant)
        grant
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Delete a grant: its rows are removed (or handed over to another grant
  that covers them) by a reconcile in the same transaction, and every host
  that lost a row is marked "revocation pending".
  """
  @spec delete_grant(actor(), Grant.t()) ::
          {:ok, Grant.t()} | {:error, :forbidden | :not_found | term()}
  def delete_grant(actor, %Grant{id: id}) do
    scope = Map.get(actor, :scope, Scope.none())

    if writer?(actor) do
      transaction(fn ->
        with %Grant{} = grant <- get_grant(scope, id),
             hosts = Expansion.affected_host_ids([grant]),
             ctx = Map.put(ctx(actor, "grant_delete"), :exclude, [grant.id]),
             {:ok, _counts} <- Expansion.reconcile(hosts, ctx),
             {:ok, deleted} <- Repo.delete(grant) do
          audit(actor, "grant_delete", grant)
          deleted
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  @doc "Changeset for the create form."
  @spec change_grant(map()) :: Ecto.Changeset.t()
  def change_grant(attrs \\ %{}), do: Grant.create_changeset(%Grant{}, attrs, %{})

  @doc ~S|"customer Acme" / "group Web" (the grant's target, for "via …" labels).|
  @spec target_label(Grant.t()) :: String.t()
  def target_label(%Grant{customer: %Customer{name: name}}), do: "customer #{name}"
  def target_label(%Grant{group: %Group{name: name}}), do: "group #{name}"
  def target_label(%Grant{customer_id: id}) when is_integer(id), do: "customer ##{id}"
  def target_label(%Grant{group_id: id}) when is_integer(id), do: "group ##{id}"

  @doc """
  `target_label/1` by grant id, for the rows of a page (one query). A target
  outside `scope` is not named (`"grant"`): a row on a host in scope can come
  from a group the viewer does not see.
  """
  @spec labels(Scope.t(), [integer()]) :: %{integer() => String.t()}
  def labels(%Scope{} = scope, grant_ids) do
    ids = scope_ids(scope)

    from(g in Grant, where: g.id in ^Enum.uniq(grant_ids), preload: [:customer, :group])
    |> Repo.all()
    |> Map.new(fn grant ->
      named? =
        member?(ids.customers, grant.customer_id) and member?(ids.groups, grant.group_id)

      {grant.id, if(named?, do: target_label(grant), else: "grant")}
    end)
  end

  @doc """
  "limited to customers Acme; groups Web" per grant id, for grants that
  carry their creator's scope (unrestricted grants are left out). Only
  customers and groups inside `scope` are named; the rest are counted.
  """
  @spec limit_labels(Scope.t(), [Grant.t()]) :: %{integer() => String.t()}
  def limit_labels(%Scope{} = scope, grants) do
    ids = scope_ids(scope)
    customers = names(Customer, Enum.flat_map(grants, &(&1.scope_customer_ids || [])))
    groups = names(Group, Enum.flat_map(grants, &(&1.scope_group_ids || [])))

    for grant <- grants,
        parts = limit_parts(grant, ids, customers, groups),
        parts != [],
        into: %{},
        do: {grant.id, "limited to " <> Enum.join(parts, "; ")}
  end

  defp limit_parts(grant, ids, customers, groups) do
    [
      {"customers", grant.scope_customer_ids, ids.customers, customers},
      {"groups", grant.scope_group_ids, ids.groups, groups}
    ]
    |> Enum.flat_map(fn
      {_label, nil, _visible, _names} -> []
      {label, [], _visible, _names} -> ["#{label}: none"]
      {label, stored, visible, names} -> [limit_part(label, stored, visible, names)]
    end)
  end

  defp limit_part(label, stored, visible, names) do
    {shown, hidden} = Enum.split_with(stored, &member?(visible, &1))
    named = Enum.map(shown, &Map.get(names, &1, "##{&1}"))

    others =
      case length(hidden) do
        0 -> []
        1 -> ["1 other"]
        n -> ["#{n} others"]
      end

    "#{label} " <> Enum.join(named ++ others, ", ")
  end

  defp names(_schema, []), do: %{}

  defp names(schema, ids),
    do:
      Repo.all(from x in schema, where: x.id in ^Enum.uniq(ids), select: {x.id, x.name})
      |> Map.new()

  @doc """
  Delete every grant of these SSH users (user delete, merge, offboarding):
  their rows are reconciled away in the same IMMEDIATE transaction — audited
  and the hosts marked "revocation pending" — before the grants go, so an
  FK cascade never removes access silently. Returns the number of grants.
  """
  @spec drop_for_users([integer()], Expansion.ctx()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drop_for_users(user_ids, ctx) do
    transaction(fn ->
      grants =
        Repo.all(
          from g in Grant,
            where: g.ssh_user_id in ^user_ids,
            preload: [:ssh_user, :customer, :group]
        )

      gone = Enum.map(grants, & &1.id)

      with true <- grants != [],
           {:ok, _} <-
             Expansion.reconcile(
               Expansion.affected_host_ids(grants),
               Map.put(ctx, :exclude, gone)
             ) do
        Repo.delete_all(from g in Grant, where: g.id in ^gone)
        Enum.each(grants, &audit(ctx, "grant_delete", &1))
      else
        false -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      length(grants)
    end)
  end

  @doc "Customers and groups a web user may target (for the create form)."
  @spec targets(Scope.t()) :: %{customers: [Customer.t()], groups: [Group.t()]}
  def targets(%Scope{} = scope) do
    %{
      customers: Repo.all(target_query(Customer, scope.customers)),
      groups: Repo.all(target_query(Group, scope.groups))
    }
  end

  defp target_query(schema, :all), do: from(x in schema, order_by: x.name)

  defp target_query(schema, slugs),
    do: from(x in schema, where: x.slug in ^slugs, order_by: x.name)

  ## Scope arithmetic (ids)

  defp scope_ids(%Scope{customers: customers, groups: groups}),
    do: %{customers: ids_of(Customer, customers), groups: ids_of(Group, groups)}

  defp ids_of(_schema, :all), do: :all
  defp ids_of(_schema, []), do: []

  defp ids_of(schema, slugs),
    do: Repo.all(from x in schema, where: x.slug in ^slugs, select: x.id)

  defp list_or_nil(:all), do: nil
  defp list_or_nil(ids), do: Enum.sort(ids)

  defp target_in_scope?(ids, changeset) do
    customer_id = Ecto.Changeset.get_field(changeset, :customer_id)
    group_id = Ecto.Changeset.get_field(changeset, :group_id)

    member?(ids.customers, customer_id) and member?(ids.groups, group_id)
  end

  # nil target in a dimension: nothing to check there (the scope list
  # stored with the grant narrows it)
  defp member?(_ids, nil), do: true
  defp member?(:all, _id), do: true
  defp member?(ids, id), do: id in ids

  # the grant's reach in each dimension lies inside the scope: its target
  # is listed, or its stored scope list is a subset
  defp within?(ids, grant) do
    dim_within?(ids.customers, grant.customer_id, grant.scope_customer_ids) and
      dim_within?(ids.groups, grant.group_id, grant.scope_group_ids)
  end

  defp dim_within?(:all, _target, _stored), do: true

  defp dim_within?(ids, target, stored) do
    (not is_nil(target) and target in ids) or
      (is_list(stored) and stored != [] and Enum.all?(stored, &(&1 in ids)))
  end

  defp ctx(actor, trigger), do: %{trigger: trigger, actor: Map.get(actor, :actor, "ssm")}

  defp audit(actor, action, grant) do
    target =
      case grant do
        %Grant{customer: %Customer{slug: slug}} -> "customer:" <> slug
        %Grant{group: %Group{slug: slug}} -> "group:" <> slug
      end

    Activity.log(%{
      activity_type: "auth",
      action: action,
      target: "#{grant.ssh_user.username}@#{target}:#{grant.login}",
      user_id: if(action == "grant_create", do: grant.ssh_user_id),
      actor_username: Map.get(actor, :actor) || actor() || "ssm",
      details: %{
        grant_id: grant.id,
        target: target,
        login: grant.login,
        scope_customer_ids: grant.scope_customer_ids,
        scope_group_ids: grant.scope_group_ids
      }
    })
  end
end
