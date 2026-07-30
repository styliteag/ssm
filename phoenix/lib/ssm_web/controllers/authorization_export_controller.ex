defmodule SsmWeb.AuthorizationExportController do
  @moduledoc """
  CSV download of the authorizations list, honoring the page's `user_id` /
  `host_id` filters — the React AuthorizationsPage export with the same
  columns (`User, Host, Login Account, SSH Options, User Enabled,
  Host Address`), built server-side instead of from browser state.
  """

  use SsmWeb, :controller

  alias Ssm.Authorizations

  @columns ["User", "Host", "Login Account", "SSH Options", "User Enabled", "Host Address"]

  def export(conn, params) do
    opts =
      [user_id: parse_id(params["user_id"]), host_id: parse_id(params["host_id"])]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    csv =
      [@columns | Enum.map(Authorizations.list_authorizations(opts), &row/1)]
      |> Enum.map_join("\n", &csv_line/1)

    filename = "authorizations-#{Date.utc_today()}.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, csv)
  end

  # Orphaned grants (legacy Diesel-era DBs) may have no user/host row.
  defp row(auth) do
    [
      (auth.user && auth.user.username) || "",
      (auth.host && auth.host.name) || "",
      auth.login,
      auth.options || "",
      if(auth.user && auth.user.enabled, do: "Yes", else: "No"),
      (auth.host && auth.host.address) || ""
    ]
  end

  defp csv_line(fields) do
    Enum.map_join(fields, ",", fn field ->
      ~s("#{String.replace(field, ~s("), ~s(""))}")
    end)
  end

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end
end
