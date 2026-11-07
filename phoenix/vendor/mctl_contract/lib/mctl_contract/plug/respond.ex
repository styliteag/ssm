defmodule MctlContract.Plug.Respond do
  @moduledoc false
  import Plug.Conn

  alias MctlContract.Envelope

  def ok(conn, status, data, meta \\ %{}),
    do: send_json(conn, status, Envelope.success(data, meta))

  def error(conn, code, message, details \\ nil),
    do: send_json(conn, Envelope.status_of(code), Envelope.error(code, message, details))

  @doc "Maps a provider error to a response."
  def provider_error(conn, :not_found), do: error(conn, "not_found", "not found")

  def provider_error(conn, :conflict),
    do: error(conn, "conflict", "conflicts with the current state")

  def provider_error(conn, :forbidden), do: error(conn, "forbidden", "not allowed for this token")

  def provider_error(conn, {:validation, details}) when is_map(details),
    do: error(conn, "validation_failed", "invalid input", details)

  def provider_error(conn, {:conflict, message}) when is_binary(message),
    do: error(conn, "conflict", message)

  def provider_error(conn, {:conflict, message, details})
      when is_binary(message) and is_map(details),
      do: error(conn, "conflict", message, details)

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
