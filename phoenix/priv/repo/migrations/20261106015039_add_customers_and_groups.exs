defmodule Ssm.Repo.Migrations.AddCustomersAndGroups do
  @moduledoc """
  mctl contract v1 data model (contract-v1 §8, ADR-0010): `customers` and
  `groups` (slug + name), `host_groups` (host ↔ group), `host.customer_id`,
  and `inserted_at`/`updated_at` on `host` (for `updated_at` and the
  `changed_after` filter).

  Additive only, so fresh and adopted Diesel-/Alembic-era databases behave
  the same. SQLite cannot add a NOT NULL column without a constant default,
  so the host timestamps are added nullable and backfilled with the
  migration time; Ecto fills them on every insert/update from then on.

  `host.customer_id` deliberately carries no FOREIGN KEY clause: SQLite's
  `DROP COLUMN` refuses columns used in a foreign key, which would make
  `down` impossible. Customers are never deleted (no API or UI path), and
  `Ssm.Hosts` only assigns existing customers.
  """

  use Ecto.Migration

  def up do
    create table(:customers) do
      add :slug, :text, null: false
      add :name, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:customers, [:slug])

    create table(:groups) do
      add :slug, :text, null: false
      add :name, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:slug])

    create table(:host_groups, primary_key: false) do
      add :host_id, references(:host, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
    end

    create unique_index(:host_groups, [:host_id, :group_id])
    create index(:host_groups, [:group_id])

    alter table(:host) do
      add :customer_id, :integer
      add :inserted_at, :utc_datetime
      add :updated_at, :utc_datetime
    end

    create index(:host, [:customer_id])
    create index(:host, [:updated_at])

    execute("""
    UPDATE host
    SET inserted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE inserted_at IS NULL OR updated_at IS NULL
    """)
  end

  def down do
    drop index(:host, [:updated_at])
    drop index(:host, [:customer_id])

    alter table(:host) do
      remove :updated_at
      remove :inserted_at
      remove :customer_id
    end

    drop table(:host_groups)
    drop table(:groups)
    drop table(:customers)
  end
end
