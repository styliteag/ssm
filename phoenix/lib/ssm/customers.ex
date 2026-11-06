defmodule Ssm.Customers do
  @moduledoc "Customers (mctl contract v1, ADR-0010): slug + name, keyset-paged by slug."

  alias Ssm.Customers.Customer
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

  @doc "Customers after `after_slug` (exclusive), sorted by slug; next key or nil."
  @spec page_customers(String.t() | nil, pos_integer()) :: {[Customer.t()], String.t() | nil}
  def page_customers(after_slug, limit) do
    Customer |> Ssm.Keyset.page(:slug, after_slug, limit)
  end
end
