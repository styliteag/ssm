defmodule Ssm.Authorizations.Authorization do
  @moduledoc """
  Grants one managed user access to one host under a remote `login`, with
  optional authorized_keys `options` (e.g. `no-pty,from="10.0.0.0/8"`,
  allow-listed by `Ssm.Authorizations.Options`). Login and comment refuse
  control characters.
  Unique per (user, host, login).

  `grant_id` is set on rows expanded from a grant (`Ssm.Grants.Expansion`,
  ADR-0012 §5): such rows are read-only and follow the grant; nil marks a
  manual row. Never cast from user input.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ssm.Authorizations.Options
  alias Ssm.ControlChars

  schema "authorization" do
    field :login, :string
    field :options, :string
    field :comment, :string

    belongs_to :host, Ssm.Hosts.Host
    belongs_to :user, Ssm.Users.User
    belongs_to :grant, Ssm.Grants.Grant
  end

  def changeset(authorization, attrs) do
    authorization
    |> base_changeset(attrs)
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
