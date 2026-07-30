defmodule SsmWeb.Api.InfoController do
  @moduledoc """
  `/api/v2/info` — python `api/v2/info.py`: `{name, version,
  alembic_revision}`. Adopted databases keep their `alembic_version` table;
  on a fresh Elixir-only database it does not exist and the revision is null.
  """

  use SsmWeb, :controller

  alias Ssm.Repo
  alias SsmWeb.Api.Envelope

  def show(conn, _params) do
    Envelope.ok(conn, %{
      name: "ssm",
      version: to_string(Application.spec(:ssm, :vsn)),
      alembic_revision: alembic_revision()
    })
  end

  defp alembic_revision do
    case Repo.query("SELECT version_num FROM alembic_version LIMIT 1") do
      {:ok, %{rows: [[revision] | _]}} -> revision
      _ -> nil
    end
  end
end
