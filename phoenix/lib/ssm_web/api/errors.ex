defmodule SsmWeb.Api.Errors do
  @moduledoc """
  Shared error responses for the JSON API — the python `AppError` hierarchy's
  status/code pairs (`core/errors.py`), rendered through the envelope.
  """

  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  def host_not_found(conn, message \\ "host not found"),
    do: Envelope.fail(conn, 404, "HOST_NOT_FOUND", message)

  def user_not_found(conn, message \\ "user not found"),
    do: Envelope.fail(conn, 404, "USER_NOT_FOUND", message)

  def key_not_found(conn, message \\ "key not found"),
    do: Envelope.fail(conn, 404, "KEY_NOT_FOUND", message)

  def authorization_not_found(conn, message \\ "authorization not found"),
    do: Envelope.fail(conn, 404, "AUTHORIZATION_NOT_FOUND", message)

  @doc "Non-integer path ids are a validation failure, as with FastAPI's typed path params."
  def path_id(raw) do
    case Params.parse_path_id(raw) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, [%{field: :id, message: "must be an integer"}]}
    end
  end

  @doc """
  Map a changeset failure after manual param validation: constraint hits
  (unique/foreign-key) are 409 CONFLICT — python catches `IntegrityError` the
  same way; anything left is a 422.
  """
  def changeset(conn, %Ecto.Changeset{} = changeset, entity) do
    if constraint_error?(changeset) do
      Envelope.fail(conn, 409, "CONFLICT", "#{entity} violates a uniqueness constraint")
    else
      Envelope.validation_failed(conn, changeset_errors(changeset))
    end
  end

  defp constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, meta}} ->
      meta[:constraint] in [:unique, :foreign]
    end)
  end

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _meta}} ->
      %{field: field, message: message}
    end)
  end
end
