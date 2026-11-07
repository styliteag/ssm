defmodule MctlContract.Migrations do
  @moduledoc """
  Versioned, portable migrations of the library tables (PostgreSQL,
  MariaDB, SQLite: only strings, text, integers and UTC datetimes; lists
  are comma separated, JSON is text). Call them from a migration of the
  tool:

      defmodule MyApp.Repo.Migrations.AddMctlContract do
        use Ecto.Migration

        def up, do: MctlContract.Migrations.up(version: 1)
        def down, do: MctlContract.Migrations.down(version: 1)
      end

  Option `only: [:tokens, :jobs, :idempotency]` creates a subset (omon
  keeps its own token table and skips `:tokens`). Pass the same `only` to
  `down/1`.
  """
  use Ecto.Migration

  @all [:tokens, :jobs, :idempotency]

  def up(opts \\ []) do
    1 = Keyword.get(opts, :version, 1)
    opts |> tables() |> Enum.each(&create_table/1)
  end

  def down(opts \\ []) do
    1 = Keyword.get(opts, :version, 1)
    opts |> tables() |> Enum.reverse() |> Enum.each(&drop_table/1)
  end

  defp tables(opts), do: Enum.filter(@all, &(&1 in Keyword.get(opts, :only, @all)))

  defp create_table(:tokens) do
    create table(:mctl_tokens) do
      add :name, :string, size: 100, null: false
      add :prefix, :string, size: 20, null: false
      add :secret_hash, :string, size: 64, null: false
      add :scopes, :string, size: 255, null: false
      add :binding, :string, size: 255
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string, size: 64
      timestamps(type: :utc_datetime)
    end

    create unique_index(:mctl_tokens, [:name])
    create unique_index(:mctl_tokens, [:secret_hash])
  end

  defp create_table(:jobs) do
    create table(:mctl_jobs) do
      add :kind, :string, size: 64, null: false
      add :state, :string, size: 16, null: false
      add :host_id, :string, size: 255
      add :progress, :text
      add :result, :text
      add :error, :text
      add :inserted_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
    end

    create index(:mctl_jobs, [:host_id])
    create index(:mctl_jobs, [:state])
  end

  defp create_table(:idempotency) do
    create table(:mctl_idempotency) do
      add :token_id, :string, size: 64, null: false
      add :key, :string, size: 255, null: false
      add :request_hash, :string, size: 64, null: false
      add :status, :integer
      add :response, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:mctl_idempotency, [:token_id, :key])
    create index(:mctl_idempotency, [:inserted_at])
  end

  defp drop_table(:tokens), do: drop(table(:mctl_tokens))
  defp drop_table(:jobs), do: drop(table(:mctl_jobs))
  defp drop_table(:idempotency), do: drop(table(:mctl_idempotency))
end
