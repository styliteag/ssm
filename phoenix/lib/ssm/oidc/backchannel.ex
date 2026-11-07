defmodule Ssm.OIDC.Backchannel do
  @moduledoc """
  OpenID Connect Back-Channel Logout 1.0 (oidc-client-v1 §7). Validates the
  `logout_token` against the provider's JWKS (an unknown `kid` gets one
  throttled refresh, `Ssm.OIDC.Jwks`; signature, `iss`, `aud`,
  `iat` ≤ 5 min, `events`, `sid` or `sub`, no `nonce`, `jti` unseen), then
  revokes the matching operators' sessions and disconnects their LiveViews.
  """

  alias Ssm.Accounts
  alias Ssm.OIDC.{Config, JtiStore, Jwks}

  @event "http://schemas.openid.net/event/backchannel-logout"
  @algs ~w(ES256 ES384 ES512 RS256 RS384 RS512 PS256 PS384 PS512 EdDSA)
  @max_age 300

  @doc "`{:ok, %{sub: .., sid: ..}}` after revoking, or `{:error, reason_atom}`."
  @spec handle(term()) :: {:ok, map()} | {:error, atom()}
  def handle(token) when is_binary(token) do
    config = Config.get()

    with {:ok, claims} <- verify(token),
         :ok <- validate(claims, config),
         :ok <- claim_jti(claims["jti"]) do
      revoke(config, claims)
    end
  end

  def handle(_), do: {:error, :missing_token}

  defp verify(token) do
    with {:ok, kid} <- header_kid(token),
         {:ok, key} <- key_for(kid),
         {true, %JOSE.JWT{fields: claims}, _} <-
           JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), @algs, token) do
      {:ok, claims}
    else
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :bad_signature}
  end

  # an unknown kid (key rotation) gets one throttled JWKS refresh, as the
  # ID-token check does (Ssm.OIDC.Jwks)
  defp key_for(kid) do
    case find(Jwks.get(), kid) do
      nil -> kid |> Jwks.refresh_for_unknown_kid() |> find(kid) |> found()
      key -> {:ok, key}
    end
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp find(jwks, kid) do
    {_, %{"keys" => keys}} = JOSE.JWK.to_map(jwks)
    Enum.find(keys, &(&1["kid"] == kid))
  end

  defp found(nil), do: {:error, :unknown_kid}
  defp found(key), do: {:ok, key}

  defp header_kid(token) do
    case JOSE.JWS.peek_protected(token) |> Jason.decode() do
      {:ok, %{"kid" => kid}} -> {:ok, kid}
      _ -> {:error, :no_kid}
    end
  end

  defp validate(claims, config) do
    checks = [
      {:iss, claims["iss"] == config.issuer},
      {:aud, config.client_id in List.wrap(claims["aud"])},
      {:iat, fresh?(claims["iat"])},
      {:events, is_map(claims["events"]) and Map.has_key?(claims["events"], @event)},
      {:subject, present?(claims["sid"]) or present?(claims["sub"])},
      {:nonce, not Map.has_key?(claims, "nonce")},
      {:jti, present?(claims["jti"])},
      {:exp, not expired?(claims["exp"])}
    ]

    case Enum.find(checks, fn {_, ok} -> not ok end) do
      nil -> :ok
      {reason, _} -> {:error, reason}
    end
  end

  defp fresh?(iat) when is_integer(iat) do
    now = System.os_time(:second)
    iat <= now + 60 and now - iat <= @max_age
  end

  defp fresh?(_), do: false

  defp expired?(exp) when is_integer(exp), do: exp < System.os_time(:second)
  defp expired?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""

  defp claim_jti(jti) do
    case JtiStore.claim(jti) do
      :ok -> :ok
      :replay -> {:error, :replay}
    end
  end

  # `sub` ends every session of the user; `sid` alone ends exactly that
  # session (checked from the session cookie), and its operator's open
  # LiveViews are disconnected so they re-check.
  defp revoke(config, claims) do
    sub = claims["sub"]
    sid = claims["sid"]
    ttl = config.session_max_hours * 3600

    if present?(sid), do: Accounts.revoke_sid(config.issuer, sid, ttl)

    ids =
      if present?(sub) do
        {:ok, ids} = Accounts.revoke_by_subject(config.issuer, sub)
        ids
      else
        Accounts.operator_ids_by_sid(config.issuer, sid)
      end

    Enum.each(ids, &Accounts.disconnect_sessions/1)
    {:ok, %{sub: sub, sid: sid}}
  end
end
