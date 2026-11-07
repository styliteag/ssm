defmodule Ssm.OIDC.Logout do
  @moduledoc """
  RP-initiated logout (oidc-client-v1 §7). After the local session is
  gone, an OIDC operator is sent to the provider's `end_session_endpoint`
  with `client_id`, `post_logout_redirect_uri` and, when available,
  `id_token_hint`. Every failure (RP logout off, no endpoint, provider
  configuration unreadable) answers `nil`: the caller then redirects as
  for a local logout. Never crashes, never logs a token.

  The raw ID token is always kept for the hint: in the session cookie
  encrypted (`Plug.Crypto.encrypt/4` with the endpoint's `secret_key_base`
  and a dedicated salt) when it is at most 1500 bytes, otherwise in
  `Ssm.OIDC.TokenStore` with only a random reference in the session. A
  `state` parameter (random per logout) is always added.
  """

  alias Ssm.OIDC.{Config, TokenStore}

  @salt "ssm oidc id_token_hint v1"
  @max_token_bytes 1500

  @doc """
  Session entries that keep `id_token` for the logout hint: `%{oidc_id_token:
  sealed}` (small token) or `%{oidc_id_token_ref: ref}` (stored server-side
  for the session maximum); `%{}` without a token.
  """
  @spec keep(term(), pos_integer()) :: map()
  def keep(id_token, max_hours) when is_binary(id_token) do
    if byte_size(id_token) <= @max_token_bytes do
      %{oidc_id_token: Plug.Crypto.encrypt(secret(), @salt, id_token)}
    else
      %{oidc_id_token_ref: TokenStore.put(id_token, max_hours * 3600)}
    end
  end

  def keep(_id_token, _max_hours), do: %{}

  @doc "Drop the server-side copy named by the session's `oidc_id_token_ref`."
  @spec forget(term()) :: :ok
  defdelegate forget(ref), to: TokenStore, as: :delete

  @doc "The raw ID token for a sealed session value; `nil` if absent or invalid."
  @spec unseal(term()) :: String.t() | nil
  def unseal(sealed) when is_binary(sealed) do
    max_age = (Config.get() || %Config{}).session_max_hours * 3600

    case Plug.Crypto.decrypt(secret(), @salt, sealed, max_age: max_age) do
      {:ok, token} -> token
      _ -> nil
    end
  end

  def unseal(_sealed), do: nil

  @doc """
  The end-session URL for the current OIDC config, or `nil` when the
  caller should fall back to the normal logout redirect.
  """
  @spec end_session_url(String.t(), term(), term()) :: String.t() | nil
  def end_session_url(post_logout_uri, sealed_id_token, ref \\ nil) do
    with %Config{rp_logout: true} = config <- Config.get(),
         endpoint when is_binary(endpoint) <- end_session_endpoint() do
      build_url(
        endpoint,
        config.client_id,
        post_logout_uri,
        unseal(sealed_id_token) || TokenStore.get(ref)
      )
    else
      _ -> nil
    end
  end

  @doc false
  @spec build_url(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def build_url(endpoint, client_id, post_logout_uri, id_token_hint) do
    uri = URI.parse(endpoint)

    params =
      [client_id: client_id, post_logout_redirect_uri: post_logout_uri, state: state()] ++
        if(id_token_hint, do: [id_token_hint: id_token_hint], else: [])

    query = Enum.join(Enum.reject([uri.query, URI.encode_query(params)], &(&1 in [nil, ""])), "&")
    URI.to_string(%{uri | query: query})
  end

  defp end_session_endpoint do
    case Oidcc.ProviderConfiguration.Worker.get_provider_configuration(Config.provider()) do
      %{end_session_endpoint: endpoint} when is_binary(endpoint) and endpoint != "" -> endpoint
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp state, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp secret, do: SsmWeb.Endpoint.config(:secret_key_base)
end
