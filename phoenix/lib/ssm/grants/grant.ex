defmodule Ssm.Grants.Grant do
  @moduledoc """
  SSH access for one SSH user per customer or host group (ADR-0012 §5),
  table `grants`. Exactly one target (`customer_id` XOR `group_id`); the
  creator's scope at creation narrows it (`scope_customer_ids` /
  `scope_group_ids`, nil = all), so a grant never reaches a host outside
  that scope, now or for future hosts. No `options`.

  Expanded into `authorization` rows with `grant_id` by
  `Ssm.Grants.Expansion`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ssm.Authorizations.Login
  alias Ssm.ControlChars

  @type t :: %__MODULE__{}

  schema "grants" do
    field :login, :string
    field :comment, :string
    field :created_by, :string
    field :scope_customer_ids, {:array, :integer}
    field :scope_group_ids, {:array, :integer}

    belongs_to :ssh_user, Ssm.Users.User
    belongs_to :customer, Ssm.Customers.Customer
    belongs_to :group, Ssm.Groups.Group

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a new grant; `created_by` and the scope lists are set by the context."
  def create_changeset(grant, attrs, internal) do
    grant
    |> cast(attrs, [:ssh_user_id, :customer_id, :group_id, :login, :comment])
    |> change(internal)
    |> validate_required([:ssh_user_id, :login, :created_by])
    |> validate_length(:login, min: 1, max: 255)
    |> validate_length(:comment, max: 1000)
    |> ControlChars.validate([:login, :comment])
    |> Login.validate()
    |> validate_one_target()
    |> foreign_key_constraint(:ssh_user_id)
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:group_id)
    |> unique_constraint([:ssh_user_id, :login],
      name: :grants_user_target_login_index,
      message: "this user already has a grant for this target and login"
    )
    |> check_constraint(:customer_id, name: :grants_one_target, message: "pick one target")
  end

  defp validate_one_target(changeset) do
    case {get_field(changeset, :customer_id), get_field(changeset, :group_id)} do
      {nil, nil} -> add_error(changeset, :customer_id, "pick a customer or a group")
      {_c, nil} -> changeset
      {nil, _g} -> changeset
      {_c, _g} -> add_error(changeset, :customer_id, "pick a customer or a group, not both")
    end
  end
end
