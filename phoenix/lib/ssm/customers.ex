defmodule Ssm.Customers do
  @moduledoc "Customers (mctl contract v1, ADR-0010): slug + name, keyset-paged by slug."

  import Ecto.Query, only: [from: 2]

  alias Ssm.Customers.Customer
  alias Ssm.Hosts.Host
  alias Ssm.Repo

  @spec get_customer_by_slug(String.t()) :: Customer.t() | nil
  def get_customer_by_slug(slug) when is_binary(slug), do: Repo.get_by(Customer, slug: slug)
  def get_customer_by_slug(_), do: nil

  @spec create_customer(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def create_customer(attrs) do
    %Customer{} |> Customer.create_changeset(attrs) |> Repo.insert()
  end

  @doc "Rename only — the slug is fixed after create."
  @spec update_customer(Customer.t(), map()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def update_customer(%Customer{} = customer, attrs) do
    customer |> Customer.update_changeset(attrs) |> Repo.update()
  end

  @doc """
  Merges customer `source` into `target` (mctl contract section 12): every
  host of the source moves to the target (its `updated_at` moves too, so
  `changed_after` readers see it), then the source is deleted, all in one
  transaction. `{:error, :not_found}` when either slug is unknown (also on a
  repeat after success).
  """
  @spec merge_customer(String.t(), String.t()) ::
          {:ok, %{moved_hosts: non_neg_integer()}} | {:error, :not_found}
  def merge_customer(source_slug, target_slug) do
    with %Customer{} = source <- get_customer_by_slug(source_slug),
         %Customer{} = target <- get_customer_by_slug(target_slug) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        {moved, _} =
          Repo.update_all(from(h in Host, where: h.customer_id == ^source.id),
            set: [customer_id: target.id, updated_at: now]
          )

        {:ok, _} = Repo.delete(source)
        %{moved_hosts: moved}
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Customers after `after_slug` (exclusive), sorted by slug; next key or nil."
  @spec page_customers(String.t() | nil, pos_integer()) :: {[Customer.t()], String.t() | nil}
  def page_customers(after_slug, limit) do
    Customer |> Ssm.Keyset.page(:slug, after_slug, limit)
  end
end
