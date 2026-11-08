defmodule Ssm.Release do
  @moduledoc """
  Tasks that run inside the packaged release, where Mix is unavailable
  (`bin/ssm eval "Ssm.Release.migrate()"`). Mirrors the python image's
  "alembic upgrade head before serving traffic" boot contract — the
  baseline migration adopts Diesel-era and Alembic-era databases in place.
  """

  @app :ssm

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Pre-upgrade report of stored rows that today's validation refuses: grant
  options (`Ssm.Authorizations.invalid_stored_options/0`; a sync keeps the
  host's line of such a key) and key fields with control characters
  (`Ssm.Users.invalid_stored_keys/0`; a bad comment is dropped when the key
  is written, bad key material is never written). Each row: `table`, `id`,
  `field`, `reason` and context. Run it in the release:
  `bin/ssm eval 'Ssm.Release.invalid_stored_rows() |> IO.inspect()'`.
  """
  @spec invalid_stored_rows() :: [map()]
  def invalid_stored_rows do
    load_app()
    [repo | _] = repos()

    {:ok, rows, _} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        Ssm.Authorizations.invalid_stored_options() ++ Ssm.Users.invalid_stored_keys()
      end)

    rows
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
