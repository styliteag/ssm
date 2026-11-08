defmodule Ssm.Customers do
  @moduledoc "Customers (mctl contract v1, ADR-0010): slug + name, keyset-paged by slug."

  import Ecto.Query, only: [from: 2]

  alias Ssm.Customers.Customer
  alias Ssm.Grants
  alias Ssm.Grants.{Expansion, Grant}
  alias Ssm.Hosts.Host
  alias Ssm.Repo

  @spec get_customer_by_slug(String.t()) :: Customer.t() | nil
  def get_customer_by_slug(slug) when is_binary(slug), do: Repo.get_by(Customer, slug: slug)
  def get_customer_by_slug(_), do: nil

  @spec create_customer(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def create_customer(attrs) do
    %Customer{} |> Customer.create_changeset(attrs) |> Repo.insert()
  end

  @doc """
  Rename only — the slug is fixed after create. Grants reference customers
  by id, so a rename changes no access; the customer's hosts are still
  reconciled in the same transaction (trigger `customer_rename`).
  """
  @spec update_customer(Customer.t(), map(), Expansion.ctx()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def update_customer(%Customer{} = customer, attrs, ctx \\ %{}) do
    Grants.transaction(fn ->
      with {:ok, updated} <- customer |> Customer.update_changeset(attrs) |> Repo.update(),
           {:ok, _} <- Expansion.reconcile(host_ids(customer.id), trigger(ctx, "customer_rename")) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp host_ids(customer_id),
    do: Repo.all(from h in Host, where: h.customer_id == ^customer_id, select: h.id)

  # grants that target the customer go with it (ON DELETE CASCADE): reconcile
  # their hosts without them first, so the removals are audited and marked
  defp drop_grants_of(customer_id, extra_hosts, ctx) do
    grants = Repo.all(from g in Grant, where: g.customer_id == ^customer_id)

    Expansion.reconcile(
      Expansion.affected_host_ids(grants) ++ extra_hosts,
      Map.put(ctx, :exclude, Enum.map(grants, & &1.id))
    )
  end

  defp trigger(ctx, name), do: Map.put(ctx, :trigger, name)

  @doc """
  Merges customer `source` into `target` (mctl contract section 12): every
  host of the source moves to the target (its `updated_at` moves too, so
  `changed_after` readers see it), then the source is deleted, all in one
  transaction. `{:error, :not_found}` when either slug is unknown (also on a
  repeat after success).

  Grants: the moved hosts are reconciled in the same IMMEDIATE transaction
  (trigger `customer_merge`): the source's grants are deleted with it, the
  target's grants reach the moved hosts. Hosts that lost rows are marked
  "revocation pending".
  """
  @spec merge_customer(String.t(), String.t(), Expansion.ctx()) ::
          {:ok, %{moved_hosts: non_neg_integer()}} | {:error, :not_found}
  def merge_customer(source_slug, target_slug, ctx \\ %{}) do
    with %Customer{} = source <- get_customer_by_slug(source_slug),
         %Customer{} = target <- get_customer_by_slug(target_slug) do
      Grants.transaction(fn ->
        now = DateTime.utc_now(:second)
        moved_ids = host_ids(source.id)

        {moved, _} =
          Repo.update_all(from(h in Host, where: h.customer_id == ^source.id),
            set: [customer_id: target.id, updated_at: now]
          )

        {:ok, _} = drop_grants_of(source.id, moved_ids, trigger(ctx, "customer_merge"))
        {:ok, _} = Repo.delete(source)
        %{moved_hosts: moved}
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Deletes an empty customer (mctl contract 0.4.0, `delete_customer`). A
  customer that still has hosts is `{:error, {:conflict, message}}` and
  stays; hosts are never moved or stripped. `{:error, :not_found}` for an
  unknown slug (also on a repeat).
  """
  @spec delete_customer(String.t(), Expansion.ctx()) ::
          :ok | {:error, :not_found | {:conflict, String.t()}}
  def delete_customer(slug, ctx \\ %{}) do
    Grants.transaction(fn ->
      case get_customer_by_slug(slug) do
        nil ->
          Repo.rollback(:not_found)

        customer ->
          case Repo.aggregate(from(h in Host, where: h.customer_id == ^customer.id), :count) do
            0 ->
              {:ok, _} = drop_grants_of(customer.id, [], trigger(ctx, "customer_delete"))
              {:ok, _} = Repo.delete(customer)
              :ok

            n ->
              Repo.rollback({:conflict, "customer #{slug} has #{n} hosts"})
          end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Customers after `after_slug` (exclusive), sorted by slug; next key or nil."
  @spec page_customers(String.t() | nil, pos_integer()) :: {[Customer.t()], String.t() | nil}
  def page_customers(after_slug, limit) do
    Customer |> Ssm.Keyset.page(:slug, after_slug, limit)
  end
end
