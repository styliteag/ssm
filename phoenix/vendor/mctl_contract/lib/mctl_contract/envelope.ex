defmodule MctlContract.Envelope do
  @moduledoc """
  Response envelope of the mctl contract, wire-identical to omon API v2:
  `{"data": …, "meta": {…}}` on success and
  `{"error": {"code", "message", "details"}}` on failure.
  """

  @codes [
    {"bad_request", 400, "The request is malformed (e.g. invalid JSON, header or query)."},
    {"unauthorized", 401, "Missing, unknown, expired or revoked token."},
    {"forbidden", 403, "The token's binding does not allow this."},
    {"insufficient_scope", 403, "The token lacks the scope this operation needs."},
    {"not_found", 404, "Unknown object, or one outside the token's binding."},
    {"conflict", 409, "The request conflicts with the current state."},
    {"idempotency_in_progress", 409, "A request with this Idempotency-Key is still running."},
    {"validation_failed", 422, "The input is invalid; `details` names the fields."},
    {"idempotency_key_reused", 422, "The Idempotency-Key was used with a different request."},
    {"rate_limited", 429, "Too many requests; see the Retry-After header."},
    {"internal_error", 500, "Unexpected server error."}
  ]

  @status Map.new(@codes, fn {code, status, _} -> {code, status} end)

  @type t :: %{data: term(), meta: map()} | %{error: map()}

  @doc "`[{code, status, description}]` of every error code."
  @spec error_codes() :: [{String.t(), pos_integer(), String.t()}]
  def error_codes, do: @codes

  @doc "HTTP status of an error code; raises on an unknown code."
  @spec status_of(String.t()) :: pos_integer()
  def status_of(code) do
    case Map.fetch(@status, code) do
      {:ok, status} -> status
      :error -> raise ArgumentError, "unknown error code #{inspect(code)}"
    end
  end

  @spec success(term(), map()) :: t()
  def success(data, meta), do: %{data: data, meta: meta}

  @spec error(String.t(), String.t(), term()) :: t()
  def error(code, message, details),
    do: %{error: %{code: code, message: message, details: details}}
end
