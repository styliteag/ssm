defmodule SsmWeb.LegacyRedirectController do
  @moduledoc """
  Permanent redirects from the old `/authorizations` page and its CSV export
  to `/access` (one vocabulary: an SSH user's access on a host, and grants that
  create it). The query string is kept, so a saved filter link still works.
  The target is always a fixed local path.
  """

  use SsmWeb, :controller

  def access(conn, _params), do: moved(conn, "/access")
  def access_export(conn, _params), do: moved(conn, "/access/export")

  defp moved(conn, path) do
    target = if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target)
  end
end
