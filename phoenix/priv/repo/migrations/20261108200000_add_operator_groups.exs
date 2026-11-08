defmodule Ssm.Repo.Migrations.AddOperatorGroups do
  @moduledoc """
  ADR-0012 phase 1: an operator's scope is customers ∧ host groups.
  `groups` is a JSON list of host-group slugs (or `["*"]`) from the
  `orbit_groups` claim, overwritten at every login like `customers`.

  Existing rows get `[]` (no group: nothing in scope), and every open OIDC
  session is ended (`session_revoked_at` = now), so each operator signs in
  again and gets a scope from the new claims instead of an empty one.
  `operators` was created after the baseline, so fresh and adopted
  Diesel-/Alembic-era databases behave the same. `down` drops the column
  (SQLite 3.35+); the revoked sessions stay revoked.
  """

  use Ecto.Migration

  def up do
    alter table(:operators) do
      add :groups, :text, null: false, default: "[]"
    end

    execute(
      "UPDATE operators SET session_revoked_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000"
    )
  end

  def down do
    alter table(:operators) do
      remove :groups
    end
  end
end
