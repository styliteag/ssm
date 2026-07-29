defmodule Ssm.Repo.Migrations.BaselineSchema do
  @moduledoc """
  The baseline schema the Elixir stack adopts at cutover — the exact table set
  the python stack's Alembic head (revision 0001) produces, captured to
  priv/repo/baseline_schema.sql and made idempotent (CREATE TABLE IF NOT
  EXISTS). Effect per database generation:

    - Alembic-era (cutover): every statement is a no-op; this version is
      simply recorded in schema_migrations — the Elixir stack owns the schema.
    - Diesel-era (Rust stack heritage): only the missing pieces are created
      (notably activity_log) — the same fill-the-gaps semantics
      backend/migrations/env.py implements with create_all(checkfirst=True).
    - empty (greenfield): the whole schema is created here.

  alembic_version / apscheduler_jobs / __diesel_schema_migrations are left in
  place: a rollback to the python image finds either its stamp or the legacy
  shape env.py knows how to stamp, so the door swings both ways.

  Every schema change AFTER this point is a normal, additive Ecto migration.
  """

  use Ecto.Migration

  def up do
    "repo/baseline_schema.sql"
    |> baseline_path()
    |> File.read!()
    |> statements()
    |> Enum.map(&refuse_destructive!/1)
    |> Enum.each(&execute/1)
  end

  # The baseline is a no-op on an existing database — that is its whole
  # contract. A regenerated file carrying DROPs would delete production data
  # on the first boot; refuse loudly instead of trusting review to catch it.
  defp refuse_destructive!(sql) do
    if Regex.match?(~r/^\s*(DROP|TRUNCATE|DELETE|RENAME)\b/i, sql) do
      raise Ecto.MigrationError,
        message:
          "baseline_schema.sql contains a destructive statement: " <>
            "#{String.slice(sql, 0, 80)}. The baseline must be pure " <>
            "CREATE TABLE/INDEX IF NOT EXISTS."
    end

    sql
  end

  # Irreversible: rolling the baseline back would drop every table (all data).
  # A teardown is a DB reset, never a down-migration.
  def down do
    raise Ecto.MigrationError, message: "the baseline schema migration is irreversible"
  end

  defp baseline_path(rel), do: Application.app_dir(:ssm, ["priv", rel])

  # One SQL statement per element: drop comment/blank lines, then split on the
  # statement-terminating ';'. No ';' appears inside the DDL, so a plain split
  # is safe.
  defp statements(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(String.trim(&1), "--") or String.trim(&1) == ""))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
