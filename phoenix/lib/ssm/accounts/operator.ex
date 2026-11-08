defmodule Ssm.Accounts.Operator do
  @moduledoc """
  A web-UI account created by an OIDC login, keyed by (`oidc_issuer`,
  `oidc_subject`) — never by e-mail or name. `Ssm.Users.User` is the SSH
  target user, hence the different name. Roles: `admin`, `operator`,
  `viewer` (read-only).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @roles ~w(admin operator viewer)

  schema "operators" do
    field :oidc_issuer, :string
    field :oidc_subject, :string
    field :source, :string, default: "oidc"
    field :name, :string
    field :email, :string
    # `email_verified` claim of the last login; `verified_email` is set once,
    # at the first verified login, and is what offboarding matches by
    field :email_verified, :boolean, default: false
    field :verified_email, :string
    field :role, :string
    # JSON slug lists from the scope claims (ADR-0012 §1), `["*"]` = all
    field :customers, :string, default: "[]"
    field :groups, :string, default: "[]"
    field :disabled_at, :utc_datetime
    field :session_revoked_at, :integer
    field :last_sid, :string
    field :last_login_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  @doc "Fields overwritten at every OIDC login."
  def login_changeset(operator, attrs) do
    operator
    |> cast(attrs, [
      :oidc_issuer,
      :oidc_subject,
      :name,
      :email,
      :email_verified,
      :verified_email,
      :role,
      :customers,
      :groups,
      :last_sid,
      :last_login_at
    ])
    |> validate_required([:oidc_issuer, :oidc_subject, :name, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:oidc_issuer, :oidc_subject])
  end

  def revoke_changeset(operator, ms), do: change(operator, session_revoked_at: ms)
end
