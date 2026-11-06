defmodule Ssm.Repo.Migrations.CreateOperators do
  @moduledoc """
  Web-UI accounts that sign in through OIDC (ADR-0011, oidc-client-v1 spec).
  `.htpasswd` users stay outside this table (they are local admins).

  A brand-new table, so fresh and adopted Diesel-/Alembic-era databases
  behave the same. `customers` is a JSON list of customer slugs (or
  `["*"]`). `session_revoked_at` (unix ms) kills every session of the
  operator that began before it (back-channel logout, disabling);
  `last_sid` maps a sid-only logout token to its operator.
  """

  use Ecto.Migration

  def change do
    create table(:operators) do
      add :oidc_issuer, :text, null: false
      add :oidc_subject, :text, null: false
      add :source, :text, null: false, default: "oidc"
      add :name, :text, null: false
      add :email, :text
      add :role, :text, null: false
      add :customers, :text, null: false, default: "[]"
      add :disabled_at, :utc_datetime
      add :session_revoked_at, :integer
      add :last_sid, :text
      add :last_login_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:operators, [:oidc_issuer, :oidc_subject])
    create index(:operators, [:last_sid])
  end
end
