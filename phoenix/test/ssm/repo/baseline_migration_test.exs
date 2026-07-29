defmodule Ssm.Repo.BaselineMigrationTest do
  @moduledoc """
  The three-way matrix for the baseline migration (see the migration's
  moduledoc): fresh database, adopted Diesel-era database, and idempotent
  re-run. The Diesel DDL below is the VERBATIM .schema dump of a real
  Diesel-era ssm.db (missing activity_log, empty alembic_version, weaker
  user_key FK) — not a synthetic approximation.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # Verbatim from `sqlite3 ssm.db .schema` of a Diesel-era production-shape DB.
  @diesel_ddl [
    """
    CREATE TABLE __diesel_schema_migrations (
           version VARCHAR(50) PRIMARY KEY NOT NULL,
           run_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """,
    """
    CREATE TABLE user (
    	id INTEGER NOT NULL PRIMARY KEY,
    	username TEXT UNIQUE NOT NULL,
    	enabled  BOOLEAN NOT NULL CHECK (enabled IN (0, 1)) DEFAULT 1
    , comment TEXT)
    """,
    """
    CREATE TABLE authorization (
    	id INTEGER NOT NULL PRIMARY KEY,
    	host_id INTEGER NOT NULL,
    	user_id INTEGER NOT NULL,
    	login TEXT NOT NULL,
    	options TEXT, comment TEXT,
    	UNIQUE(user_id, host_id, login),
    	FOREIGN KEY (host_id) REFERENCES host(id) ON DELETE CASCADE,
    	FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
    )
    """,
    """
    CREATE TABLE "host" (
      id integer PRIMARY KEY NOT NULL,
      name text UNIQUE NOT NULL,
      username text NOT NULL,
      address text NOT NULL,
      port integer NOT NULL,
      key_fingerprint text,
      jump_via integer, disabled BOOLEAN NOT NULL DEFAULT 0, comment TEXT,
      FOREIGN KEY (jump_via) REFERENCES "host" (id) ON DELETE CASCADE,
      UNIQUE (address, port)
    )
    """,
    """
    CREATE TABLE "user_key" (
        id INTEGER PRIMARY KEY NOT NULL,
        key_type TEXT NOT NULL,
        key_base64 TEXT NOT NULL,
        name TEXT,  -- Renamed from comment
        extra_comment TEXT,  -- New field
        user_id INTEGER NOT NULL,
        FOREIGN KEY (user_id) REFERENCES user(id)
    )
    """,
    """
    CREATE TABLE apscheduler_jobs (
    	id VARCHAR(191) NOT NULL,
    	next_run_time FLOAT,
    	job_state BLOB NOT NULL,
    	PRIMARY KEY (id)
    )
    """,
    "CREATE INDEX ix_apscheduler_jobs_next_run_time ON apscheduler_jobs (next_run_time)",
    """
    CREATE TABLE alembic_version (
    	version_num VARCHAR(32) NOT NULL,
    	CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
    )
    """
  ]

  @app_tables ~w(host user authorization user_key activity_log)

  setup %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "baseline_test.db")

    {:ok, repo_pid} =
      Ssm.Repo.start_link(
        name: nil,
        database: db_path,
        pool_size: 1,
        pool: DBConnection.ConnectionPool
      )

    Ssm.Repo.put_dynamic_repo(repo_pid)

    on_exit(fn ->
      Ssm.Repo.put_dynamic_repo(Ssm.Repo)

      # The repo supervisor terminates with :shutdown; a plain stop expecting
      # :normal races it — any exit here is fine, the DB file is throwaway.
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{repo_pid: repo_pid}
  end

  defp migrate!(repo_pid) do
    path = Application.app_dir(:ssm, ["priv", "repo", "migrations"])
    Ecto.Migrator.run(Ssm.Repo, path, :up, all: true, dynamic_repo: repo_pid, log: false)
  end

  defp table_names do
    %{rows: rows} =
      Ssm.Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")

    List.flatten(rows)
  end

  defp table_sql(table) do
    %{rows: [[sql]]} =
      Ssm.Repo.query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])

    sql
  end

  test "creates the full schema on a fresh database and is idempotent", %{repo_pid: repo_pid} do
    applied = migrate!(repo_pid)
    assert applied == [20_260_101_000_000]

    tables = table_names()

    for table <- @app_tables do
      assert table in tables, "missing table #{table}"
    end

    %{rows: index_rows} =
      Ssm.Repo.query!("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'")

    assert ["idx_activity_log_timestamp"] in index_rows
    assert ["idx_activity_log_type"] in index_rows

    # No python-era bookkeeping tables appear on a greenfield database.
    refute "alembic_version" in tables
    refute "apscheduler_jobs" in tables

    # Second run: nothing left to apply.
    assert migrate!(repo_pid) == []
  end

  test "adopts a Diesel-era database: fills gaps, touches nothing else", %{repo_pid: repo_pid} do
    for ddl <- @diesel_ddl, do: Ssm.Repo.query!(ddl)

    Ssm.Repo.query!(
      "INSERT INTO \"host\" (name, username, address, port) VALUES ('web1', 'root', '10.0.0.1', 22)"
    )

    Ssm.Repo.query!("INSERT INTO \"user\" (username) VALUES ('alice')")
    diesel_user_key_sql = table_sql("user_key")

    assert migrate!(repo_pid) == [20_260_101_000_000]

    tables = table_names()
    assert "activity_log" in tables, "adoption must create the missing activity_log table"

    # Existing data untouched.
    %{rows: [[1]]} = Ssm.Repo.query!("SELECT count(*) FROM \"host\"")
    %{rows: [["web1"]]} = Ssm.Repo.query!("SELECT name FROM \"host\"")
    %{rows: [[1]]} = Ssm.Repo.query!("SELECT count(*) FROM \"user\"")

    # Existing tables keep their Diesel DDL verbatim — proof nothing was
    # dropped/recreated (the dump's inline comment survives only then).
    assert table_sql("user_key") == diesel_user_key_sql
    assert table_sql("user_key") =~ "Renamed from comment"

    # Python-era bookkeeping stays for two-way rollback compatibility.
    assert "alembic_version" in tables
    assert "apscheduler_jobs" in tables
    assert "__diesel_schema_migrations" in tables

    # The new activity_log is usable, including its epoch server default.
    Ssm.Repo.query!(
      "INSERT INTO activity_log (activity_type, action, target, actor_username) " <>
        "VALUES ('host', 'created', 'web1', 'admin')"
    )

    %{rows: [[ts]]} = Ssm.Repo.query!("SELECT timestamp FROM activity_log")
    assert is_integer(ts) and ts > 1_700_000_000
  end
end
