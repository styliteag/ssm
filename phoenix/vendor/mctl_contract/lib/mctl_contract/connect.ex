defmodule MctlContract.Connect do
  @moduledoc """
  "Connect Mission Control" (US-API-09, ADR-0009 §2): the service token
  `mission-control` an admin creates in the tool's UI (Setup → API tokens),
  the same in every tool. The env-managed `mission-control-env` token
  (`MctlContract.Bootstrap`) is a different token and is never touched here.

    * `create/3` – a fresh token with the chosen scopes; a new secret
      replaces any earlier `mission-control` token (`ensure_service_token/4`
      of the tool's `MctlContract.TokenStore`). The plain token is returned
      once and never stored or logged.
    * `rotate/2` – a new secret, same scopes; the old secret stops working.
    * `revoke/1` – the token stays listed as revoked.
    * `status/1` – what the UI shows (prefix, scopes, state, last use);
      never the secret.
    * `connector_entry/2`, `connector_snippet/2` – the entry for mctl's
      `MCTL_CONNECTORS_FILE` (`{"kind", "name", "url", "token_file"}`).

  The tool does the rest: admin-only access and the audit entry
  (`mctl.connect.create` / `.rotate` / `.revoke`, with the token name and
  scopes, never the token).

  Store requirements: `ensure_service_token/4`, and for revoke/status/
  rotate the optional callbacks `revoke_service_token/1` and
  `service_token_status/1` (`MctlContract.Tokens.Ecto` has all of them).
  """

  alias MctlContract.TokenStore

  @name "mission-control"
  @secret_bytes 32

  @type status :: %{
          name: String.t(),
          prefix: String.t(),
          scopes: [String.t()],
          state: String.t(),
          last_used_at: DateTime.t() | nil,
          last_used_ip: String.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Name of the UI-created service token."
  @spec name() :: String.t()
  def name, do: @name

  @doc "Scopes an admin may choose, in display order."
  @spec scopes() :: [String.t()]
  def scopes, do: TokenStore.scopes()

  @doc """
  Create (or replace) the token with `scopes`. `{:ok, plain_token}` — show
  it once — or `{:error, :no_scopes | {:unknown_scopes, list} | term}`.
  """
  @spec create(module(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def create(store, prefix, scopes) when is_binary(prefix) do
    with {:ok, scopes} <- check_scopes(scopes) do
      plain =
        prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)

      case store.ensure_service_token(
             @name,
             TokenStore.hash(plain),
             TokenStore.prefix(plain, prefix),
             scopes
           ) do
        :ok -> {:ok, plain}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "A new secret with the current scopes; `{:error, :not_found}` without a token."
  @spec rotate(module(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rotate(store, prefix) do
    case status(store) do
      %{scopes: scopes} -> create(store, prefix, scopes)
      nil -> {:error, :not_found}
    end
  end

  @doc "Revoke the token: `:revoked`, or `:none` when nothing active."
  @spec revoke(module()) :: :revoked | :none
  def revoke(store) do
    Code.ensure_loaded(store)

    if function_exported?(store, :revoke_service_token, 1),
      do: store.revoke_service_token(@name),
      else: raise(ArgumentError, "#{inspect(store)} cannot revoke service tokens")
  end

  @doc "The token as the UI shows it, or nil when none was ever created."
  @spec status(module()) :: status() | nil
  def status(store) do
    Code.ensure_loaded(store)

    if function_exported?(store, :service_token_status, 1),
      do: store.service_token_status(@name),
      else: raise(ArgumentError, "#{inspect(store)} cannot report service tokens")
  end

  @doc "The `MCTL_CONNECTORS_FILE` entry of this tool (no token, a token file path)."
  @spec connector_entry(String.t(), String.t()) :: map()
  def connector_entry(kind, base_url) do
    %{
      "kind" => kind,
      "name" => kind,
      "url" => base_url |> String.trim() |> String.trim_trailing("/"),
      "token_file" => "/run/secrets/mctl_#{kind}_token"
    }
  end

  @doc "`connector_entry/2` as a pretty JSON list, ready to paste."
  @spec connector_snippet(String.t(), String.t()) :: String.t()
  def connector_snippet(kind, base_url),
    do: Jason.encode!([connector_entry(kind, base_url)], pretty: true)

  defp check_scopes(scopes) when is_list(scopes) do
    scopes = Enum.uniq(scopes)

    case Enum.reject(scopes, &(&1 in TokenStore.scopes())) do
      [] when scopes != [] -> {:ok, Enum.filter(TokenStore.scopes(), &(&1 in scopes))}
      [] -> {:error, :no_scopes}
      unknown -> {:error, {:unknown_scopes, unknown}}
    end
  end

  defp check_scopes(_scopes), do: {:error, :no_scopes}
end
