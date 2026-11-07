defmodule MctlContract.TokenStore do
  @moduledoc """
  Where a tool keeps its contract tokens. `MctlContract.Tokens.Ecto` is the
  default; omon adapts its own token table.

  Only the SHA-256 (hex, lowercase) of a full token is stored.
  """
  alias MctlContract.Principal

  @callback verify(token :: String.t()) ::
              {:ok, Principal.t()} | {:error, :invalid | :expired | :revoked}

  @callback touch(Principal.t(), ip :: String.t()) :: :ok

  @doc """
  Create or rotate the service token `name`. A NEW secret replaces the
  token (fresh, active). The SAME secret leaves revocation and expiry
  untouched: a revoked or expired token answers `{:error, :revoked}` /
  `{:error, :expired}` and stays that way.
  """
  @callback ensure_service_token(
              name :: String.t(),
              sha256_hex :: String.t(),
              prefix :: String.t(),
              scopes :: [String.t()]
            ) :: :ok | {:error, :revoked | :expired | term()}

  @doc """
  Optional: revoke the active token `name` (the env-managed service token
  when `MCTL_TOKEN_FILE` is gone). `:revoked` or `:none` (nothing active).
  """
  @callback revoke_service_token(name :: String.t()) :: :revoked | :none

  @doc """
  Optional: the token `name` for a UI (`MctlContract.Connect.status/1`):
  `%{name, prefix, scopes, state ("active" | "revoked" | "expired"),
  last_used_at, last_used_ip, updated_at}`, or nil. Never the secret.
  """
  @callback service_token_status(name :: String.t()) :: map() | nil

  @optional_callbacks revoke_service_token: 1, service_token_status: 1

  @doc "Contract scopes."
  @spec scopes() :: [String.t()]
  def scopes, do: ~w(read setup commands)

  @doc "SHA-256 of a token, hex lowercase."
  @spec hash(String.t()) :: String.t()
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  The shown prefix of a token: the tool prefix plus 4 characters of the
  secret (`omon_AbCd`). Without a tool prefix (or one the token lacks): the
  first 8 characters.
  """
  @spec prefix(String.t(), String.t() | nil) :: String.t()
  def prefix(token, tool_prefix \\ nil)

  def prefix(token, tool_prefix) when is_binary(tool_prefix) do
    if String.starts_with?(token, tool_prefix),
      do: tool_prefix <> String.slice(token, String.length(tool_prefix), 4),
      else: prefix(token, nil)
  end

  def prefix(token, nil), do: String.slice(token, 0, 8)
end
