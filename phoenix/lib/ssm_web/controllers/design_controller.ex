defmodule SsmWeb.DesignController do
  @moduledoc """
  Persists the theme choice in year-long cookies (`ssm_design` / `ssm_mode`)
  and bounces back to the referring page. Mounted OUTSIDE the auth wall so
  the login page is themable too. Setting mode to "" deletes the cookie —
  that is "Auto": the design's native mode wins.
  """

  use SsmWeb, :controller

  alias SsmWeb.Design

  @cookie_opts [max_age: 60 * 60 * 24 * 365, same_site: "Lax"]

  def design(conn, params) do
    conn
    |> put_resp_cookie("ssm_design", Design.validate(params["design"]), @cookie_opts)
    |> bounce()
  end

  def mode(conn, params) do
    case Design.validate_mode(params["mode"]) do
      nil -> conn |> delete_resp_cookie("ssm_mode") |> bounce()
      mode -> conn |> put_resp_cookie("ssm_mode", mode, @cookie_opts) |> bounce()
    end
  end

  defp bounce(conn) do
    path =
      case get_req_header(conn, "referer") do
        [referer | _] -> URI.parse(referer).path || "/"
        _ -> "/"
      end

    redirect(conn, to: path)
  end
end
