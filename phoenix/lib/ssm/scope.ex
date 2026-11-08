defmodule Ssm.Scope do
  @moduledoc """
  The host scope of a web user (ADR-0012 §1, §3) and the one place that
  turns it into queries. Every host-bearing read and write of the web UI
  passes a scope to its context, which filters through `filter/3` or
  checks with `fetch_host/2` / `in_scope?/2`.

  A host is in scope when (customers is `:all` or `host.customer` is in
  customers) **and** (groups is `:all` or the host has at least one group in
  groups). A host without customer is in scope only for customers `:all`; a
  host without group only for groups `:all`. An out-of-scope host behaves
  like a missing one.

  `.htpasswd` admins, OIDC admins, `/api/v2` bearer tokens and the mctl
  contract API are global (`global/0`). An unknown or unreadable stored scope
  is empty (`none/0`): fail closed.
  """

  import Ecto.Query

  alias Ssm.Customers.Customer
  alias Ssm.Groups.Group
  alias Ssm.Hosts.Host
  alias Ssm.Repo

  defstruct customers: [], groups: []

  @type dimension :: :all | [String.t()]
  @type t :: %__MODULE__{customers: dimension(), groups: dimension()}

  @doc "Every host."
  @spec global() :: t()
  def global, do: %__MODULE__{customers: :all, groups: :all}

  @doc "No host."
  @spec none() :: t()
  def none, do: %__MODULE__{}

  @doc """
  Scope from stored slug lists (`[\"*\"]` = all). Anything that is not a
  list of strings counts as no slug at all.
  """
  @spec new(term(), term()) :: t()
  def new(customers, groups),
    do: %__MODULE__{customers: dimension(customers), groups: dimension(groups)}

  defp dimension(["*"]), do: :all

  defp dimension(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 not in ["", "*"])), do: list, else: []
  end

  defp dimension(_), do: []

  @doc "The scope of a web user (`current_user` map); none when it carries no scope."
  @spec of(map() | nil) :: t()
  def of(%{scope: %__MODULE__{} = scope}), do: scope
  def of(_user), do: none()

  @doc "True when the scope covers every host, hosts without customer or group included."
  @spec global?(t()) :: boolean()
  def global?(%__MODULE__{customers: :all, groups: :all}), do: true
  def global?(%__MODULE__{}), do: false

  @doc "Query of the ids of all hosts in scope."
  @spec host_ids(t()) :: Ecto.Query.t()
  def host_ids(%__MODULE__{} = scope) do
    from(h in Host, select: h.id)
    |> by_customers(scope.customers)
    |> by_groups(scope.groups)
  end

  defp by_customers(query, :all), do: query

  defp by_customers(query, slugs) do
    ids = from(c in Customer, where: c.slug in ^slugs, select: c.id)
    from h in query, where: h.customer_id in subquery(ids)
  end

  defp by_groups(query, :all), do: query

  defp by_groups(query, slugs) do
    ids =
      from hg in "host_groups",
        join: g in Group,
        on: g.id == hg.group_id,
        where: g.slug in ^slugs,
        select: hg.host_id

    from h in query, where: h.id in subquery(ids)
  end

  @doc """
  Restrict `query` to rows whose `field` (a host id, default `:host_id`)
  names a host in scope. A global scope leaves the query unchanged.
  """
  @spec filter(Ecto.Queryable.t(), t(), atom()) :: Ecto.Query.t()
  def filter(query, scope, field \\ :host_id)

  def filter(query, %__MODULE__{customers: :all, groups: :all}, _field),
    do: Ecto.Queryable.to_query(query)

  def filter(query, %__MODULE__{} = scope, field),
    do: where(query, [x], field(x, ^field) in subquery(host_ids(scope)))

  @doc "All hosts in scope, by id."
  @spec hosts(t()) :: Ecto.Query.t()
  def hosts(%__MODULE__{} = scope), do: filter(Host, scope, :id)

  @doc "Is the host with this id in scope? A missing host never is."
  @spec in_scope?(t(), integer() | nil) :: boolean()
  def in_scope?(%__MODULE__{} = scope, host_id) when is_integer(host_id),
    do: Repo.exists?(from h in hosts(scope), where: h.id == ^host_id)

  def in_scope?(_scope, _host_id), do: false

  @doc "Are all these host ids in scope? (true for an empty list)"
  @spec all_in_scope?(t(), [integer()]) :: boolean()
  def all_in_scope?(%__MODULE__{} = scope, host_ids) do
    ids = Enum.uniq(host_ids)

    Enum.all?(ids, &is_integer/1) and
      Repo.aggregate(from(h in hosts(scope), where: h.id in ^ids), :count) == length(ids)
  end

  @doc "The host when it exists and is in scope; otherwise `{:error, :not_found}`."
  @spec fetch_host(t(), term()) :: {:ok, Host.t()} | {:error, :not_found}
  def fetch_host(%__MODULE__{} = scope, id) when is_integer(id) do
    case Repo.one(from h in hosts(scope), where: h.id == ^id) do
      nil -> {:error, :not_found}
      host -> {:ok, host}
    end
  end

  def fetch_host(_scope, _id), do: {:error, :not_found}
end
