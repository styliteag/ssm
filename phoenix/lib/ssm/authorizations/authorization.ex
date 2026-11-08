defmodule Ssm.Authorizations.Authorization do
  @moduledoc """
  Grants one managed user access to one host under a remote `login`, with
  optional authorized_keys `options` (e.g. `no-pty,from="10.0.0.0/8"`,
  allow-listed by `Ssm.Authorizations.Options`). Login and comment refuse
  control characters; the login must also pass `Ssm.Authorizations.Login`
  (not for copies of stored grants, see `copy_changeset/2`).
  Unique per (user, host, login).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ssm.Authorizations.{Login, Options}
  alias Ssm.ControlChars

  schema "authorization" do
    field :login, :string
    field :options, :string
    field :comment, :string

    belongs_to :host, Ssm.Hosts.Host
    belongs_to :user, Ssm.Users.User
  end

  def changeset(authorization, attrs) do
    authorization
    |> base_changeset(attrs)
    |> Login.validate(:login)
    |> Options.validate_changeset()
  end

  @doc """
  For copies of grants that are already stored (user split/merge): the
  options are copied as they are, without today's options validation, so a
  legacy option never blocks a merge. The sync treats such options as
  invalid stored options (keeps the host's line of the key).
  """
  def copy_changeset(authorization, attrs), do: base_changeset(authorization, attrs)

  defp base_changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [:host_id, :user_id, :login, :options, :comment])
    |> validate_required([:host_id, :user_id, :login])
    |> validate_length(:login, min: 1, max: 255)
    |> ControlChars.validate([:login, :comment])
    # ecto_sqlite3 derives the name as <table>_<cols>_index (see Ssm.Hosts.Host).
    |> unique_constraint([:user_id, :host_id, :login])
    |> foreign_key_constraint(:host_id)
    |> foreign_key_constraint(:user_id)
  end
end
