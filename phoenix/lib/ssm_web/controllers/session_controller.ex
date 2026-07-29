defmodule SsmWeb.SessionController do
  @moduledoc """
  Login/logout as plain request/response cycles — session cookies can only be
  written from a controller, not a LiveView (the ../dashboard
  session_controller pattern). The form lives in `SsmWeb.LoginLive`.
  """

  use SsmWeb, :controller

  alias Ssm.Auth.Htpasswd
  alias SsmWeb.UserAuth

  def create(conn, %{"username" => username, "password" => password}) do
    if Htpasswd.verify(htpasswd_path(), username, password) do
      UserAuth.log_in_user(conn, username)
    else
      conn
      |> put_flash(:error, "Invalid username or password.")
      |> redirect(to: ~p"/sign-in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid username or password.")
    |> redirect(to: ~p"/sign-in")
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp htpasswd_path, do: Application.get_env(:ssm, :htpasswd_path, ".htpasswd")
end
