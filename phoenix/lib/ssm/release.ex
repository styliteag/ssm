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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
