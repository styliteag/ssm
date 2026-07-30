defmodule SsmWeb.Api.AuthPlug do
  @moduledoc """
  Bearer access-token guard for `/api/v2/*` — python `protected_router()`:
  missing/invalid/expired/wrong-type tokens all yield 401 `AUTH_REQUIRED`
  in the envelope. The verified subject lands in `conn.assigns.api_user`.
  """

  import Plug.Conn

  alias Ssm.Auth.Token
  alias SsmWeb.Api.Envelope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{"sub" => subject}} <- Token.verify(token, "access") do
      assign(conn, :api_user, subject)
    else
      _ ->
        conn
        |> Envelope.fail(401, "AUTH_REQUIRED", "authentication required")
        |> halt()
    end
  end
end
