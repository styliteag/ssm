defmodule Ssm.Repo.Migrations.CreateGrants do
  @moduledoc """
  ADR-0012 phase 2: grants give an SSH user access per customer or host
  group (`Ssm.Grants.Grant`), expanded into normal `"authorization"` rows.

    * `grants`: `ssh_user_id`, exactly one target (`customer_id` XOR
      `group_id`, CHECK), the creator's scope at creation as id lists
      (`scope_customer_ids` / `scope_group_ids`, JSON, NULL = all), `login`,
      `comment`, `created_by`. Unique per user, target and login. Every FK
      is `ON DELETE CASCADE`. No `options` (a sync never renders them for
      grants).
    * `"authorization".grant_id`: the grant a row was expanded from (NULL =
      manual row), `ON DELETE CASCADE`.
    * `pending_revocations`: hosts whose rows a reconcile removed and that
      no successful sync has reached since (`Ssm.Diffs.Revocations`).

  Additive only: `"authorization"` comes from the baseline (same columns on
  fresh and adopted Diesel-/Alembic-era databases), and SQLite allows
  `ADD COLUMN … REFERENCES` with a NULL default, so both origins migrate.

  `down` is refused: SQLite's `DROP COLUMN` refuses a column used in a
  foreign key, and leaving `grant_id` behind with `grants` gone breaks every
  later write to `"authorization"` ("no such table: main.grants"). Roll back
  by restoring the database backup taken before the upgrade.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE grants (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ssh_user_id INTEGER NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
      customer_id INTEGER REFERENCES customers (id) ON DELETE CASCADE,
      group_id INTEGER REFERENCES groups (id) ON DELETE CASCADE,
      scope_customer_ids TEXT,
      scope_group_ids TEXT,
      login TEXT NOT NULL,
      comment TEXT,
      created_by TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT grants_one_target CHECK ((customer_id IS NULL) <> (group_id IS NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX grants_user_target_login_index
    ON grants (ssh_user_id, login, IFNULL(customer_id, 0), IFNULL(group_id, 0))
    """)

    create index(:grants, [:customer_id])
    create index(:grants, [:group_id])

    alter table(:authorization) do
      add :grant_id, references(:grants, on_delete: :delete_all)
    end

    create index(:authorization, [:grant_id])

    create table(:pending_revocations, primary_key: false) do
      add :host_id, references(:host, on_delete: :delete_all), primary_key: true
      add :reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "CreateGrants cannot be rolled back: SQLite cannot drop \"authorization\".grant_id " <>
          "(used in a foreign key); restore the database backup taken before the upgrade"
  end
end
