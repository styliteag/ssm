defmodule Ssm.OrbitMonitor.Connect do
  @moduledoc """
  "Connect Orbit Monitor": the UI-created service token `orbit-monitor` in
  ssm's `ssm_` token store, with scope `read` only. STYLiTE Orbit Monitor's
  special agent sends it to read the key check export
  (`GET /api/export/checkmk`). Creating the token is the opt-in: without
  it nothing reads the export.

  A `read` token also reads the mctl contract (`/api/mctl/v1`); a scope
  for the export alone would need a new contract scope.

  Audit entries `omon.connect.create` / `.rotate` / `.revoke` (type
  `auth`, scopes and shown prefix, never the token). Admin checks are the
  caller's job (`SsmWeb.ApiTokensLive`). The Mission Control tokens are
  different tokens and never touched here.
  """

  alias MctlContract.TokenStore
  alias MctlContract.Tokens.Ecto, as: Store
  alias Ssm.Activity

  @name "orbit-monitor"
  @prefix "ssm_"
  @scopes ["read"]
  @secret_bytes 32
  @export_path "/api/export/checkmk"

  @doc "Name of the token."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The token as the UI shows it (never the secret), or nil."
  @spec status() :: map() | nil
  def status, do: Store.service_token_status(@name)

  @doc "The export URL Orbit Monitor reads (public URL from `PHX_HOST`)."
  @spec export_url() :: String.t()
  def export_url, do: SsmWeb.Endpoint.url() <> @export_path

  @doc "The base URL to enter in Orbit Monitor's special agent."
  @spec base_url() :: String.t()
  def base_url, do: SsmWeb.Endpoint.url()

  @doc "Create (or replace) the token. `{:ok, plain}` is shown once."
  @spec create(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(actor), do: issue("omon.connect.create", actor)

  @doc "A new secret; the old one stops working. `{:error, :not_found}` without a token."
  @spec rotate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def rotate(actor) do
    if status(), do: issue("omon.connect.rotate", actor), else: {:error, :not_found}
  end

  @doc "Revoke; `:revoked` or `:none`."
  @spec revoke(String.t()) :: :revoked | :none
  def revoke(actor) do
    case Store.revoke_service_token(@name) do
      :revoked ->
        audit("omon.connect.revoke", actor, status())
        :revoked

      :none ->
        :none
    end
  end

  defp issue(action, actor) do
    plain = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)

    case Store.ensure_service_token(
           @name,
           TokenStore.hash(plain),
           TokenStore.prefix(plain, @prefix),
           @scopes
         ) do
      :ok ->
        audit(action, actor, status())
        {:ok, plain}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit(action, actor, status) do
    Activity.log(%{
      activity_type: "auth",
      action: action,
      target: @name,
      actor_username: actor,
      details: %{scopes: status.scopes, prefix: status.prefix}
    })
  end
end
