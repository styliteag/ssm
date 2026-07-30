defmodule SsmWeb.Api.AuthController do
  @moduledoc """
  `/api/v2/auth/{login,refresh,logout,me}` — python `api/v2/auth.py`.
  Login verifies against the same htpasswd file as the web session; tokens
  are stateless HS256 JWTs (`Ssm.Auth.Token`). `logout` is a client-side
  no-op kept for wire parity.
  """

  use SsmWeb, :controller

  alias Ssm.Auth.Htpasswd
  alias Ssm.Auth.Token
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @login_spec [
    username: [type: :string, required: true, min_len: 1, max_len: 128],
    password: [type: :string, required: true, min_len: 1, max_len: 1024]
  ]

  @refresh_spec [
    refresh_token: [type: :string, required: true, min_len: 1]
  ]

  def login(conn, params) do
    case Params.validate(params, @login_spec) do
      {:ok, %{username: username, password: password}} ->
        if Htpasswd.verify(htpasswd_path(), username, password) do
          Envelope.ok(conn, token_pair(username))
        else
          Envelope.fail(conn, 401, "INVALID_CREDENTIALS", "invalid credentials")
        end

      {:error, errors} ->
        Envelope.validation_failed(conn, errors)
    end
  end

  def refresh(conn, params) do
    with {:ok, %{refresh_token: token}} <- Params.validate(params, @refresh_spec),
         {:ok, %{"sub" => subject}} <- Token.verify(token, "refresh") do
      Envelope.ok(conn, token_pair(subject))
    else
      {:error, :invalid_token} ->
        Envelope.fail(conn, 401, "AUTH_REQUIRED", "invalid token")

      {:error, errors} ->
        Envelope.validation_failed(conn, errors)
    end
  end

  def logout(conn, _params) do
    # Stateless JWT: the client discards its tokens.
    Envelope.ok(conn, %{logged_out: true})
  end

  def me(conn, _params) do
    Envelope.ok(conn, %{username: conn.assigns.api_user})
  end

  defp token_pair(subject) do
    %{
      access_token: Token.issue_access(subject),
      refresh_token: Token.issue_refresh(subject),
      token_type: "Bearer"
    }
  end

  defp htpasswd_path, do: Application.get_env(:ssm, :htpasswd_path, ".htpasswd")
end
