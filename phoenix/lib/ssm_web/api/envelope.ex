defmodule SsmWeb.Api.Envelope do
  @moduledoc """
  The v2 response envelope — python `core/envelope.py` verbatim:
  `{success, data, error: {code, message, details} | nil, meta | nil}`.
  Clients branch on the stable `error.code`, never on the message.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @spec ok(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def ok(conn, data, opts \\ []) do
    conn
    |> put_status(Keyword.get(opts, :status, 200))
    |> json(%{success: true, data: data, error: nil, meta: Keyword.get(opts, :meta)})
  end

  @spec fail(Plug.Conn.t(), integer(), String.t(), String.t(), map() | nil) :: Plug.Conn.t()
  def fail(conn, status, code, message, details \\ nil) do
    conn
    |> put_status(status)
    |> json(%{
      success: false,
      data: nil,
      error: %{code: code, message: message, details: details},
      meta: nil
    })
  end

  @spec validation_failed(Plug.Conn.t(), [map()]) :: Plug.Conn.t()
  def validation_failed(conn, errors) do
    fail(conn, 422, "VALIDATION_FAILED", "request validation failed", %{errors: errors})
  end

  @doc "Meta block for list endpoints (python `Meta`): absent fields are null."
  @spec meta(keyword()) :: map()
  def meta(fields) do
    %{
      total: Keyword.get(fields, :total),
      page: Keyword.get(fields, :page),
      page_size: Keyword.get(fields, :page_size)
    }
  end
end
