defmodule Ssm.Hosts do
  @moduledoc """
  Managed SSH hosts — the context behind `/api/v2/hosts` and the Hosts page.
  Every SSH operation elsewhere resolves its `Ssm.Ssh.Target` through
  `target_for/1`, which walks the `jump_via` chain.

  Functions that take an `Ssm.Scope` first serve the web UI (ADR-0012): an
  out-of-scope host is treated as missing. The scope-less ones are global
  (`/api/v2`, mctl contract, background jobs).
  """

  import Ecto.Query

  alias Ssm.Hosts.Host
  alias Ssm.{Repo, Scope}
  alias Ssm.Ssh.Target

  @spec list_hosts() :: [Host.t()]
  def list_hosts, do: list_hosts(Scope.global())

  @doc "Hosts in `scope`, by id."
  @spec list_hosts(Scope.t()) :: [Host.t()]
  def list_hosts(%Scope{} = scope),
    do: scope |> Scope.hosts() |> order_by([h], h.id) |> Repo.all()

  @spec get_host(integer()) :: Host.t() | nil
  def get_host(id), do: Repo.get(Host, id)

  @doc "A host in `scope`, or nil (missing and out of scope look the same)."
  @spec get_host(Scope.t(), term()) :: Host.t() | nil
  def get_host(%Scope{} = scope, id) do
    case Scope.fetch_host(scope, id) do
      {:ok, host} -> host
      {:error, :not_found} -> nil
    end
  end

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

  @doc """
  True when ssm logs in as a user other than `root`: ssm (no sudo) then
  sees and manages only the `authorized_keys` files that user can read and
  write, usually just its own (onboarding v2 §4, "reduced functionality").
  """
  @spec limited?(Host.t()) :: boolean()
  def limited?(%Host{username: username}), do: username != "root"

  @doc "Why a host is `limited?/1` (one sentence for UI and API), or nil."
  @spec limited_reason(Host.t()) :: String.t() | nil
  def limited_reason(%Host{} = host) do
    if limited?(host) do
      "ssm logs in as #{host.username}, not root: it can only read and manage the " <>
        "authorized_keys files this user can access (usually only its own)"
    end
  end

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

  # Where ssm connects to (and as whom): changing them retargets every sync of
  # the host, so only a global user may (ADR-0012 review).
  @connection_fields ~w(address port username key_fingerprint jump_via)a

  @doc """
  `update_host/2` for a web user. The host is re-read through `scope`
  (`{:error, :not_found}` outside it). A scoped user cannot change the
  connection fields (`address`, `port`, `username`, `key_fingerprint`,
  `jump_via`; they are dropped from `attrs`) and cannot change a host that
  other hosts use as their jump host (`{:error, :jump_host}`).
  """
  @spec update_host(Scope.t(), Host.t(), map()) ::
          {:ok, Host.t()} | {:error, Ecto.Changeset.t() | :not_found | :jump_host}
  def update_host(%Scope{} = scope, %Host{id: id}, attrs) do
    with {:ok, host} <- Scope.fetch_host(scope, id),
         :ok <- check_jump_host(scope, host) do
      update_host(host, scoped_attrs(scope, attrs))
    end
  end

  @doc "May a user with `scope` change this host at all (not a jump host in use)?"
  @spec editable?(Scope.t(), Host.t()) :: boolean()
  def editable?(%Scope{} = scope, %Host{} = host), do: check_jump_host(scope, host) == :ok

  defp check_jump_host(scope, host) do
    if Scope.global?(scope) or jump_dependents(host) == [], do: :ok, else: {:error, :jump_host}
  end

  defp scoped_attrs(scope, attrs) do
    if Scope.global?(scope) do
      attrs
    else
      Map.drop(attrs, @connection_fields ++ Enum.map(@connection_fields, &Atom.to_string/1))
    end
  end

  @doc """
  `delete_host/1` for a web user: the host must be in `scope`, and a host
  that other hosts use as their jump host is never deleted here (the
  `jump_via` cascade would delete them too) – `{:error, {:jump_host_in_use,
  names}}`, for every user, as in the mctl contract.
  """
  @spec delete_host(Scope.t(), Host.t()) ::
          {:ok, Host.t()}
          | {:error, Ecto.Changeset.t() | :not_found | {:jump_host_in_use, [String.t()]}}
  def delete_host(%Scope{} = scope, %Host{id: id}) do
    with {:ok, host} <- Scope.fetch_host(scope, id) do
      case jump_dependents(host) do
        [] -> delete_host(host)
        names -> {:error, {:jump_host_in_use, names}}
      end
    end
  end

  @doc """
  Delete a host. Its activity entries keep their text but lose the host id:
  SQLite reuses ids, and a later host must not inherit them (scope filter).
  """
  @spec delete_host(Host.t()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def delete_host(%Host{} = host) do
    Repo.transaction(fn ->
      case Repo.delete(host) do
        {:ok, deleted} ->
          detach_activity(deleted.id)
          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp detach_activity(host_id) do
    Repo.update_all(from(l in Ssm.Activity.ActivityLog, where: l.host_id == ^host_id),
      set: [host_id: nil]
    )
  end

  @doc "Names of the hosts that use `host` as their jump host."
  @spec jump_dependents(Host.t()) :: [String.t()]
  def jump_dependents(%Host{id: id}),
    do: Repo.all(from h in Host, where: h.jump_via == ^id, order_by: h.name, select: h.name)

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

  @spec count_hosts(Scope.t()) :: non_neg_integer()
  def count_hosts(%Scope{} = scope \\ Scope.global()),
    do: scope |> Scope.hosts() |> Repo.aggregate(:count)

  @spec count_disabled_hosts(Scope.t()) :: non_neg_integer()
  def count_disabled_hosts(%Scope{} = scope \\ Scope.global()),
    do: scope |> Scope.hosts() |> where([h], h.disabled == true) |> Repo.aggregate(:count)

  @doc "Hosts in `scope` eligible to be a jump host for `host` (any other host)."
  @spec jump_candidates(Scope.t(), Host.t() | nil) :: [Host.t()]
  def jump_candidates(%Scope{} = scope, host) do
    query = scope |> Scope.hosts() |> order_by([h], h.name)

    case host do
      %Host{id: id} -> Repo.all(where(query, [h], h.id != ^id))
      nil -> Repo.all(query)
    end
  end

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
