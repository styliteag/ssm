defmodule SsmWeb.HealthController do
  @moduledoc """
  Unauthenticated healthcheck for container orchestration (plan §9: replaces
  the python stack's wget check). Reports app version and verifies the
  database answers a trivial query.
  """

  use SsmWeb, :controller

  def show(conn, _params) do
    db_ok? =
      match?({:ok, _}, Ecto.Adapters.SQL.query(Ssm.Repo, "SELECT 1", []))

    status = if db_ok?, do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(%{
      status: if(db_ok?, do: "ok", else: "degraded"),
      version: to_string(Application.spec(:ssm, :vsn)),
      database: if(db_ok?, do: "ok", else: "error")
    })
  end
end
