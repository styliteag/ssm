defmodule SsmWeb.CheckmkExportController do
  @moduledoc """
  `GET /api/export/checkmk` (`Ssm.Diffs.CheckmkExport`): the stored
  periodic key check of every enabled host for STYLiTE Orbit Monitor's
  special agent. Plain JSON in the Orbit Dashboard export shape, no
  `/api/v2` envelope; auth by `SsmWeb.Plugs.ServiceTokenAuth` (scope
  `read`). Never opens an SSH connection.
  """
  use SsmWeb, :controller

  def show(conn, _params), do: json(conn, Ssm.Diffs.CheckmkExport.current())
end
