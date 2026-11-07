defmodule MctlContract.Principal do
  @moduledoc """
  The caller of a contract request, built by the `MctlContract.TokenStore`
  from a verified token.

    * `id` – token id (used to key Idempotency-Key records)
    * `name` – token name (`mission-control`)
    * `prefix` – first characters of the token, safe to show
    * `scopes` – contract scopes (`read`, `setup`, `commands`)
    * `binding` – tool-specific restriction (e.g. a folder or group), or nil
    * `extra` – anything the tool's provider needs (e.g. omon's `Scope`)
    * `ip` – the client IP of the request (set by `MctlContract.Plug`),
      for the provider's audit rows
  """

  @enforce_keys [:id, :name, :prefix, :scopes]
  defstruct [:id, :name, :prefix, :binding, :ip, scopes: [], extra: nil]

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          prefix: String.t(),
          scopes: [String.t()],
          binding: term(),
          extra: term(),
          ip: String.t() | nil
        }

  @doc "Whether the principal holds `scope`."
  @spec has_scope?(t(), String.t()) :: boolean()
  def has_scope?(%__MODULE__{scopes: scopes}, scope), do: scope in scopes
end
