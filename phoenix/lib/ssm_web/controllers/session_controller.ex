defmodule SsmWeb.SessionController do
  @moduledoc """
  Login/logout as plain request/response cycles — session cookies can only be
  written from a controller, not a LiveView (the ../dashboard
  session_controller pattern). The form lives in `SsmWeb.LoginLive`.
  """

  use SsmWeb, :controller

  alias Ssm.Auth.Htpasswd
  alias Ssm.LoginThrottle
  alias SsmWeb.UserAuth

  @invalid "Invalid username or password."
  @locked "Too many failed attempts, try again later"

  def create(conn, %{"username" => username, "password" => password})
      when is_binary(username) and is_binary(password) do
    with :ok <- LoginThrottle.check(conn.remote_ip, username),
         true <- Htpasswd.verify(htpasswd_path(), username, password) do
      LoginThrottle.record_success(username)
      UserAuth.log_in_user(conn, username)
    else
      {:error, _retry_after} -> deny(conn, @locked)
      false -> fail(conn, username)
    end
  end

  def create(conn, params) do
    username = if is_binary(params["username"]), do: params["username"], else: ""

    case LoginThrottle.check(conn.remote_ip, username) do
      :ok -> fail(conn, username)
      {:error, _retry_after} -> deny(conn, @locked)
    end
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp fail(conn, username) do
    LoginThrottle.record_failure(conn.remote_ip, username)
    deny(conn, @invalid)
  end

  defp deny(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  defp htpasswd_path, do: Application.get_env(:ssm, :htpasswd_path, ".htpasswd")
end
