defmodule Ssm.OIDC.Flow do
  @moduledoc """
  Authorization Code flow with PKCE S256, state and nonce (oidc-client-v1
  §1). `start/1` builds the authorize URL and the single-use values the
  caller keeps in the session; `finish/3` exchanges the code, lets oidcc
  validate the ID token (signature, iss, aud, exp, nonce, PKCE) and turns
  the claims into an operator. No access or refresh token is kept; the raw
  ID token is returned only for the logout hint (`Ssm.OIDC.Logout`).
  """

  require Logger

  alias Ssm.Accounts
  alias Ssm.OIDC.{Config, Jwks, Roles}

  @max_iat_age 600
  @max_iat_skew 120

  @type pending :: %{state: String.t(), nonce: String.t(), verifier: String.t()}
  @type login :: %{
          operator: Ssm.Accounts.Operator.t(),
          sid: String.t() | nil,
          id_token: String.t() | nil,
          amr: [String.t()]
        }

  @doc "`{:ok, url, pending}`; `pending` goes into the session."
  @spec start(String.t()) :: {:ok, String.t(), pending()} | {:error, :provider_unavailable}
  def start(redirect_uri) do
    config = Config.get()
    pending = %{state: random(), nonce: random(), verifier: random()}

    opts = %{
      redirect_uri: redirect_uri,
      scopes: ["openid", "profile", "email"],
      state: pending.state,
      nonce: pending.nonce,
      pkce_verifier: pending.verifier,
      require_pkce: true
    }

    case Oidcc.create_redirect_url(
           Config.provider(),
           config.client_id,
           config.client_secret,
           opts
         ) do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url), pending}
      {:error, reason} -> unavailable(reason)
    end
  end

  @doc """
  Finish the login. `{:error, {code, sub}}` carries a reason code for the
  audit log (never shown to the user) and the subject when known.
  """
  @spec finish(String.t(), pending(), String.t()) :: {:ok, login()} | {:error, {atom(), term()}}
  def finish(code, pending, redirect_uri) do
    config = Config.get()

    opts = %{
      redirect_uri: redirect_uri,
      nonce: pending.nonce,
      pkce_verifier: pending.verifier,
      require_pkce: true,
      refresh_jwks: &refresh_jwks/2
    }

    case Oidcc.retrieve_token(
           code,
           Config.provider(),
           config.client_id,
           config.client_secret,
           opts
         ) do
      {:ok, token} -> with_id_token(from_claims(token.id.claims, config), token.id.token)
      {:error, reason} -> token_error(reason)
    end
  end

  # The raw ID token is handed on only for the RP-initiated logout hint.
  defp with_id_token({:ok, login}, raw), do: {:ok, Map.put(login, :id_token, raw)}
  defp with_id_token(error, _raw), do: error

  defp from_claims(%{"sub" => sub} = claims, config) when is_binary(sub) and sub != "" do
    with :ok <- check_iat(claims["iat"], sub),
         {:ok, role, customers} <- resolve(claims, config, sub),
         {:ok, operator} <- upsert(claims, config, sub, role, customers),
         :ok <- ensure_enabled(operator) do
      {:ok, %{operator: operator, sid: sid(claims), amr: amr(claims)}}
    end
  end

  defp from_claims(_claims, _config), do: {:error, {:invalid_token, nil}}

  # oidcc checks `exp`; `iat` must also be recent (10 min) and not ahead of
  # our clock by more than 2 min.
  defp check_iat(iat, sub) when is_integer(iat) do
    age = System.os_time(:second) - iat
    if age <= @max_iat_age and age >= -@max_iat_skew, do: :ok, else: {:error, {:iat_invalid, sub}}
  end

  defp check_iat(_iat, sub), do: {:error, {:iat_invalid, sub}}

  # An unknown `kid` makes oidcc re-fetch the JWKS; `Ssm.OIDC.Jwks` allows
  # that once a minute for the whole app, otherwise keeps the cached keys
  # (verification then fails with no matching key).
  defp refresh_jwks(_jwks, kid), do: {:ok, Jwks.refresh_for_unknown_kid(kid)}

  defp resolve(claims, config, sub) do
    case Roles.resolve(claims, config) do
      {:ok, role, customers} -> {:ok, role, customers}
      {:error, reason} -> {:error, {reason, sub}}
    end
  end

  defp upsert(claims, config, sub, role, customers) do
    attrs = %{
      name: display_name(claims, sub),
      email: string(claims["email"]),
      # only `true` counts (OIDC Core 5.1: boolean)
      email_verified: claims["email_verified"] == true,
      role: role,
      customers: customers,
      sid: sid(claims)
    }

    case Accounts.upsert_from_oidc(config.issuer, sub, attrs) do
      {:ok, operator} -> {:ok, operator}
      {:error, _changeset} -> {:error, {:upsert_failed, sub}}
    end
  end

  defp ensure_enabled(%{disabled_at: nil}), do: :ok
  defp ensure_enabled(operator), do: {:error, {:disabled, operator.oidc_subject}}

  defp display_name(claims, sub) do
    Enum.find_value(["name", "preferred_username", "email"], sub, fn key ->
      case string(claims[key]) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp sid(claims), do: string(claims["sid"])
  defp amr(%{"amr" => amr}) when is_list(amr), do: Enum.filter(amr, &is_binary/1)
  defp amr(_), do: []
  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  defp token_error(reason) do
    Logger.warning("OIDC token exchange refused: #{summarize(reason)}")
    {:error, {:token_invalid, nil}}
  end

  defp unavailable(reason) do
    Logger.error("OIDC provider unavailable: #{summarize(reason)}")
    {:error, :provider_unavailable}
  end

  # Error terms can embed response bodies; log the shape only.
  defp summarize(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp summarize(reason) when is_tuple(reason), do: reason |> elem(0) |> summarize()
  defp summarize(_reason), do: "error"

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
