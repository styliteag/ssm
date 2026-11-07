defmodule Ssm.Mctl.Connect do
  @moduledoc """
  "Connect Mission Control" (US-API-09): the UI-created service token
  `mission-control` in ssm's own `ssm_` token store, on top of
  `MctlContract.Connect`. Adds the audit entries
  (`mctl.connect.create` / `.rotate` / `.revoke`, with actor, scopes and the
  shown prefix, never the token). Admin checks are the caller's job
  (`SsmWeb.ApiTokensLive`). The env-managed `mission-control-env` token
  (`Ssm.Mctl.Boot`) is a different token and never touched here.
  """

  alias MctlContract.Connect, as: Core
  alias MctlContract.Tokens.Ecto, as: Store
  alias Ssm.Activity

  @prefix "ssm_"
  @kind "ssm"

  @doc "The token as the UI shows it, or nil."
  @spec status() :: Core.status() | nil
  def status, do: Core.status(Store)

  @doc "Scopes an admin may choose."
  @spec scopes() :: [String.t()]
  def scopes, do: Core.scopes()

  @doc """
  The public URL ssm uses for links (`SsmWeb.Endpoint.url/0`, from
  `PHX_HOST` in production), without a trailing slash.
  """
  @spec base_url() :: String.t()
  def base_url, do: SsmWeb.Endpoint.url()

  @doc "The `MCTL_CONNECTORS_FILE` snippet for this ssm."
  @spec snippet() :: String.t()
  def snippet, do: Core.connector_snippet(@kind, base_url())

  @doc "Create (or replace) the token. `{:ok, plain}` is shown once."
  @spec create(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def create(actor, scopes),
    do: issue("mctl.connect.create", actor, Core.create(Store, @prefix, scopes))

  @doc "New secret, same scopes."
  @spec rotate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def rotate(actor), do: issue("mctl.connect.rotate", actor, Core.rotate(Store, @prefix))

  @doc "Revoke; `:revoked` or `:none`."
  @spec revoke(String.t()) :: :revoked | :none
  def revoke(actor) do
    before = status()

    case Core.revoke(Store) do
      :revoked ->
        audit("mctl.connect.revoke", actor, before)
        :revoked

      :none ->
        :none
    end
  end

  defp issue(action, actor, {:ok, plain}) do
    audit(action, actor, status())
    {:ok, plain}
  end

  defp issue(_action, _actor, {:error, _reason} = error), do: error

  defp audit(action, actor, status) do
    Activity.log(%{
      activity_type: "auth",
      action: action,
      target: Core.name(),
      actor_username: actor,
      details: %{scopes: status.scopes, prefix: status.prefix}
    })
  end
end
