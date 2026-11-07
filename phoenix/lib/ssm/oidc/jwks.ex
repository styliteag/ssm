defmodule Ssm.OIDC.Jwks do
  @moduledoc """
  The provider's signing keys, with one throttled refresh for an unknown
  `kid` (key rotation at the provider): at most one JWKS fetch per minute
  for the whole app, shared by the ID-token check (`Ssm.OIDC.Flow`) and the
  back-channel logout (`Ssm.OIDC.Backchannel`). Unknown kids beyond that
  keep the cached keys, so a flood of forged tokens cannot hammer the
  provider.
  """

  alias Ssm.OIDC.Config
  alias Ssm.RateLimit

  @doc "The cached JWKS of the provider worker (`JOSE.JWK` set)."
  @spec get() :: JOSE.JWK.t()
  def get, do: :oidcc_provider_configuration_worker.get_jwks(Config.provider())

  @doc """
  Ask the worker to re-fetch the JWKS for `kid` (throttled), then return
  the current set. The worker handles the request before the following
  `get/0` call, so the returned set already holds new keys.
  """
  @spec refresh_for_unknown_kid(String.t()) :: JOSE.JWK.t()
  def refresh_for_unknown_kid(kid) do
    if RateLimit.hit(:oidc_jwks_refresh, 1, 60) == :ok do
      Oidcc.ProviderConfiguration.Worker.refresh_jwks_for_unknown_kid(Config.provider(), kid)
    end

    get()
  end
end
