defmodule Ssm.Repo.Migrations.CreateOidcRevokedSids do
  @moduledoc """
  Back-channel logout by `sid` (oidc-client-v1 §7): a revoked (issuer, sid)
  pair ends exactly that session wherever the cookie is checked. Rows live
  as long as an OIDC session can (`expires_at`, unix seconds) and are pruned
  on insert. A brand-new table, so fresh and adopted Diesel-/Alembic-era
  databases behave the same.
  """

  use Ecto.Migration

  def change do
    create table(:oidc_revoked_sids, primary_key: false) do
      add :issuer, :text, null: false
      add :sid, :text, null: false
      add :expires_at, :integer, null: false
    end

    create unique_index(:oidc_revoked_sids, [:issuer, :sid])
    create index(:oidc_revoked_sids, [:expires_at])
  end
end
