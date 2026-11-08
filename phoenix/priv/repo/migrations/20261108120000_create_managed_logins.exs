defmodule Ssm.Repo.Migrations.CreateManagedLogins do
  @moduledoc """
  `managed_logins`: every remote login that ever held a grant on a host
  (`Ssm.Authorizations.ManagedLogin`). A sync covers these logins too, so
  deleting the last grant of a login (or disabling its users) empties its
  authorized_keys file instead of leaving the keys behind.

  New table, plural name like the other post-Diesel tables. Seeded from the
  distinct `(host_id, login)` pairs of `"authorization"`; rows whose host is
  gone (adopted Diesel-era DBs can carry such orphans, FKs were not always
  enforced) are skipped, so fresh and adopted databases both migrate. The
  row follows its host (`ON DELETE CASCADE`); `down` drops the table.
  """

  use Ecto.Migration

  def up do
    create table(:managed_logins) do
      add :host_id, references(:host, on_delete: :delete_all), null: false
      add :login, :text, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:managed_logins, [:host_id, :login])

    execute("""
    INSERT OR IGNORE INTO managed_logins (host_id, login, inserted_at)
    SELECT DISTINCT a.host_id, a.login, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    FROM "authorization" AS a
    WHERE a.login IS NOT NULL AND a.host_id IN (SELECT id FROM "host")
    """)
  end

  def down do
    drop table(:managed_logins)
  end
end
