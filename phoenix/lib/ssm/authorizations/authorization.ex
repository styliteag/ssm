defmodule Ssm.Authorizations.Authorization do
  @moduledoc """
  Grants one managed user access to one host under a remote `login`, with
  optional authorized_keys `options` (e.g. `no-pty,from="10.0.0.0/8"`).
  Unique per (user, host, login).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "authorization" do
    field :login, :string
    field :options, :string
    field :comment, :string

    belongs_to :host, Ssm.Hosts.Host
    belongs_to :user, Ssm.Users.User
  end

  def changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [:host_id, :user_id, :login, :options, :comment])
    |> validate_required([:host_id, :user_id, :login])
    |> validate_length(:login, min: 1, max: 255)
    # ecto_sqlite3 derives the name as <table>_<cols>_index (see Ssm.Hosts.Host).
    |> unique_constraint([:user_id, :host_id, :login])
    |> foreign_key_constraint(:host_id)
    |> foreign_key_constraint(:user_id)
  end
end
