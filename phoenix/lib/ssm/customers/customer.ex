defmodule Ssm.Customers.Customer do
  @moduledoc """
  A customer (mctl contract v1). Owned by mission control (ADR-0010): mctl
  creates and renames customers here; ssm assigns hosts to them.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "customers" do
    field :slug, :string
    field :name, :string
    timestamps(type: :utc_datetime)
  end

  defdelegate create_changeset(customer, attrs), to: Ssm.Slug
  defdelegate update_changeset(customer, attrs), to: Ssm.Slug
end
