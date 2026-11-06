defmodule Ssm.Repo.Migrations.CreateHostChecks do
  @moduledoc """
  Persisted result of the periodic key check (US-API-08, contract-v1 C4):
  one row per host in `host_checks` — state (`synced`, `drift`, `error`),
  the per-user drift summary (fingerprints and comments, never key
  material), the error, when it was checked and when the result last
  changed. Until now the only record was an ETS cache that filled when
  someone opened the diff page.

  A new table only, so fresh and adopted Diesel-/Alembic-era databases
  behave the same. The row follows its host (`ON DELETE CASCADE`); `down`
  drops the table.
  """

  use Ecto.Migration

  def up do
    create table(:host_checks, primary_key: false) do
      add :host_id, references(:host, on_delete: :delete_all), primary_key: true
      add :state, :text, null: false
      add :logins, :integer, null: false, default: 0
      add :drift, :text, null: false, default: "[]"
      add :error_code, :text
      add :error, :text
      add :checked_at, :utc_datetime, null: false
      add :changed_at, :utc_datetime, null: false
    end

    create index(:host_checks, [:changed_at])
  end

  def down do
    drop table(:host_checks)
  end
end
