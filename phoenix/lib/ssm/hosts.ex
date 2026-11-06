defmodule Ssm.Hosts do
  @moduledoc """
  Managed SSH hosts — the context behind `/api/v2/hosts` and the Hosts page.
  Every SSH operation elsewhere resolves its `Ssm.Ssh.Target` through
  `target_for/1`, which walks the `jump_via` chain.
  """

  import Ecto.Query

  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Ssh.Target

  @spec list_hosts() :: [Host.t()]
  def list_hosts, do: Repo.all(from h in Host, order_by: h.id)

  @spec get_host(integer()) :: Host.t() | nil
  def get_host(id), do: Repo.get(Host, id)

  @doc """
  Resolve a host reference — an id (integer or decimal string) or a host
  name — to an existing host's id. An id wins over a host named like it.
  """
  @spec resolve_host_ref(term()) :: {:ok, integer()} | :error
  def resolve_host_ref(ref) when is_integer(ref) and ref > 0 do
    if Repo.exists?(from h in Host, where: h.id == ^ref), do: {:ok, ref}, else: :error
  end

  def resolve_host_ref(ref) when is_binary(ref) and ref != "" do
    with {id, ""} <- Integer.parse(ref),
         {:ok, id} <- resolve_host_ref(id) do
      {:ok, id}
    else
      _ ->
        case Repo.one(from h in Host, where: h.name == ^ref, select: h.id) do
          nil -> :error
          id -> {:ok, id}
        end
    end
  end

  def resolve_host_ref(_ref), do: :error

  @spec fetch_host(integer()) :: {:ok, Host.t()} | {:error, :not_found}
  def fetch_host(id) do
    case Repo.get(Host, id) do
      nil -> {:error, :not_found}
      host -> {:ok, host}
    end
  end

  @spec create_host(map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def create_host(attrs) do
    %Host{} |> Host.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Create a host and assign its customer/groups (slugs) in one transaction;
  unknown slugs roll the insert back (see `update_membership/2`).
  """
  @spec create_host_with_membership(map(), map()) ::
          {:ok, Host.t()} | {:error, Ecto.Changeset.t() | {:validation, map()}}
  def create_host_with_membership(attrs, membership) do
    Repo.transaction(fn ->
      with {:ok, host} <- create_host(attrs),
           {:ok, host} <- update_membership(host, membership) do
        host
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec update_host(Host.t(), map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def update_host(%Host{} = host, attrs) do
    host |> Host.changeset(attrs) |> Repo.update()
  end

  @spec delete_host(Host.t()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def delete_host(%Host{} = host), do: Repo.delete(host)

  @spec change_host(Host.t(), map()) :: Ecto.Changeset.t()
  def change_host(%Host{} = host, attrs \\ %{}), do: Host.changeset(host, attrs)

  @doc "A host with `customer` and `groups` preloaded, or nil."
  @spec get_host_with_membership(integer()) :: Host.t() | nil
  def get_host_with_membership(id) do
    case Repo.get(Host, id) do
      nil -> nil
      host -> Repo.preload(host, [:customer, :groups])
    end
  end

  @doc """
  Keyset page of hosts by id (membership preloaded). Filters: `:customer`
  and `:group` (slugs), `:changed_after` (`DateTime`, exclusive).
  Returns the page and the id to continue after, or nil.
  """
  @spec page_hosts(integer() | nil, pos_integer(), map()) :: {[Host.t()], integer() | nil}
  def page_hosts(after_id, limit, filters) do
    {hosts, next} =
      Host
      |> filter_customer(Map.get(filters, :customer))
      |> filter_group(Map.get(filters, :group))
      |> filter_changed_after(Map.get(filters, :changed_after))
      |> Ssm.Keyset.page(:id, after_id, limit)

    {Repo.preload(hosts, [:customer, :groups]), next}
  end

  defp filter_customer(query, nil), do: query

  defp filter_customer(query, slug) do
    from h in query, join: c in assoc(h, :customer), where: c.slug == ^slug
  end

  defp filter_group(query, nil), do: query

  defp filter_group(query, slug) do
    from h in query,
      where:
        h.id in subquery(
          from hg in "host_groups",
            join: g in Ssm.Groups.Group,
            on: g.id == hg.group_id,
            where: g.slug == ^slug,
            select: hg.host_id
        )
  end

  defp filter_changed_after(query, nil), do: query

  defp filter_changed_after(query, %DateTime{} = at) do
    at = DateTime.truncate(at, :second)
    from h in query, where: h.updated_at > ^at
  end

  @doc """
  Change a host's `name`, `customer` (slug or nil) and/or `groups` (slugs) —
  only the keys present in `attrs`. Unknown slugs are refused with
  `{:error, {:validation, %{"customer" | "groups" => [message]}}}`; a name
  conflict returns the changeset. Always bumps `updated_at`.
  """
  @spec update_membership(Host.t(), map()) ::
          {:ok, Host.t()}
          | {:error, {:validation, map()}}
          | {:error, Ecto.Changeset.t()}
  def update_membership(%Host{} = host, attrs) do
    host = Repo.preload(host, [:customer, :groups])

    with {:ok, changes} <- resolve_customer(%{}, attrs),
         {:ok, changes} <- resolve_groups(changes, attrs) do
      host
      |> Host.changeset(Map.take(attrs, [:name]))
      |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now(:second))
      |> put_membership(changes)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, [:customer, :groups], force: true)}
        {:error, _} = error -> error
      end
    end
  end

  defp resolve_customer(changes, %{customer: nil}), do: {:ok, Map.put(changes, :customer, nil)}

  defp resolve_customer(changes, %{customer: slug}) do
    case Ssm.Customers.get_customer_by_slug(slug) do
      nil -> {:error, {:validation, %{"customer" => ["unknown customer #{inspect(slug)}"]}}}
      customer -> {:ok, Map.put(changes, :customer, customer)}
    end
  end

  defp resolve_customer(changes, _attrs), do: {:ok, changes}

  defp resolve_groups(changes, %{groups: slugs}) when is_list(slugs) do
    case Ssm.Groups.fetch_by_slugs(slugs) do
      {groups, []} ->
        {:ok, Map.put(changes, :groups, groups)}

      {_groups, missing} ->
        {:error, {:validation, %{"groups" => ["unknown group(s): #{Enum.join(missing, ", ")}"]}}}
    end
  end

  defp resolve_groups(changes, _attrs), do: {:ok, changes}

  defp put_membership(changeset, changes) do
    Enum.reduce(changes, changeset, fn
      {:customer, nil}, cs -> Ecto.Changeset.put_change(cs, :customer_id, nil)
      {:customer, customer}, cs -> Ecto.Changeset.put_change(cs, :customer_id, customer.id)
      {:groups, groups}, cs -> Ecto.Changeset.put_assoc(cs, :groups, groups)
    end)
  end

  @doc """
  Hosts whose username/address break `Ssm.Hosts.SshFields` (rows from
  before the rule): `[{host, [:username | :address]}]`. SSH to them, and to
  hosts behind them, is refused until the record is fixed.
  """
  @spec list_hosts_unsafe_for_ssh() :: [{Host.t(), [atom()]}]
  def list_hosts_unsafe_for_ssh do
    for host <- list_hosts(),
        problems = Ssm.Hosts.SshFields.problems(host),
        problems != [],
        do: {host, problems}
  end

  @spec count_hosts() :: non_neg_integer()
  def count_hosts, do: Repo.aggregate(Host, :count)

  @spec count_disabled_hosts() :: non_neg_integer()
  def count_disabled_hosts,
    do: Repo.aggregate(from(h in Host, where: h.disabled == true), :count)

  @doc "Hosts eligible to be a jump host for `host` (any other host)."
  @spec jump_candidates(Host.t() | nil) :: [Host.t()]
  def jump_candidates(nil), do: list_hosts()

  def jump_candidates(%Host{id: id}),
    do: Repo.all(from h in Host, where: h.id != ^id, order_by: h.name)

  @doc "Pin one host's SSH host key (ADR-0008). See `Ssm.Hosts.HostKeys.pin/2`."
  defdelegate pin_host_key(host, opts \\ []), to: Ssm.Hosts.HostKeys, as: :pin

  @doc "Accept a changed host key the operator confirmed. See `Ssm.Hosts.HostKeys.accept/3`."
  defdelegate accept_host_key(host, fingerprint, opts \\ []), to: Ssm.Hosts.HostKeys, as: :accept

  @doc "Admin action \"Pin host keys now\". See `Ssm.Hosts.HostKeys.pin_all/1`."
  defdelegate pin_host_keys_now(opts \\ []), to: Ssm.Hosts.HostKeys, as: :pin_all

  @doc "Build the SSH target for `host`, resolving its jump chain from the DB."
  @spec target_for(Host.t()) :: Target.t()
  def target_for(%Host{} = host), do: Target.from_host(host, &get_host/1)
end
