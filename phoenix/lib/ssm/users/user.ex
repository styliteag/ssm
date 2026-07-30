defmodule Ssm.Users.User do
  @moduledoc """
  A managed SSH key owner — NOT a web login account (web auth is the htpasswd
  file). Table name is singular (`user`), Diesel parity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user" do
    field :username, :string
    field :enabled, :boolean, default: true
    field :comment, :string

    has_many :keys, Ssm.Users.UserKey
    has_many :authorizations, Ssm.Authorizations.Authorization
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :enabled, :comment])
    |> validate_required([:username])
    |> validate_length(:username, min: 1, max: 255)
    # ecto_sqlite3 derives the name as <table>_<col>_index (see Ssm.Hosts.Host).
    |> unique_constraint(:username)
  end
end
