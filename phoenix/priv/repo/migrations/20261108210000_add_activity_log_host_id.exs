defmodule Ssm.Repo.Migrations.AddActivityLogHostId do
  @moduledoc """
  ADR-0012 phase 1: a scoped operator sees only the activity entries of
  hosts in its scope, so host-bearing entries record the host's id.

  Nullable and without a FOREIGN KEY clause (SQLite's `DROP COLUMN` refuses
  columns used in a foreign key, which would make `down` impossible – the
  `host.customer_id` precedent). `Ssm.Hosts.delete_host/1` clears the id of
  a deleted host's entries, because SQLite reuses host ids. Older entries
  keep `NULL`: they are visible to global users only. `activity_log` comes
  from the baseline, which creates it identically on fresh and adopted
  Diesel-/Alembic-era databases, so a plain ADD COLUMN fits both.
  """

  use Ecto.Migration

  def up do
    alter table(:activity_log) do
      add :host_id, :integer
    end

    create index(:activity_log, [:host_id])
  end

  def down do
    drop index(:activity_log, [:host_id])

    alter table(:activity_log) do
      remove :host_id
    end
  end
end
