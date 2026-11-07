defmodule MctlContract.IdempotencyStore do
  @moduledoc """
  Storage of `Idempotency-Key` records for POSTs, keyed by token id and
  key, kept 24 hours. `MctlContract.Idempotency.Ecto` (table
  `mctl_idempotency`) is the default.

  `claim/3` answers `{:new, ref}` for a first request, `{:replay, %{status,
  response}}` for a finished one with the same request hash,
  `:in_progress` while it still runs and `:mismatch` for another request.
  """

  @type ref :: term()

  @callback claim(token_id :: String.t(), key :: String.t(), request_hash :: String.t()) ::
              {:new, ref()}
              | {:replay, %{status: pos_integer(), response: String.t()}}
              | :in_progress
              | :mismatch

  @callback complete(ref(), status :: pos_integer(), body :: String.t()) :: :ok
  @callback release(ref()) :: :ok
end
