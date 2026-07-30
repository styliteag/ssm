defmodule Ssm.Auth.Token do
  @moduledoc """
  HS256 JWT issue/verify for the JSON API — wire-compatible with the python
  stack's `auth/jwt.py` (same claims `sub`/`iat`/`exp`/`type`, same TTLs:
  access 15 min, refresh 7 days), so existing API clients keep working across
  the cutover. Implemented on `:crypto` directly; no JWT dependency.
  """

  @access_ttl 15 * 60
  @refresh_ttl 7 * 24 * 60 * 60

  @header_b64 %{"alg" => "HS256", "typ" => "JWT"}
              |> Jason.encode!()
              |> Base.url_encode64(padding: false)

  @spec issue_access(String.t()) :: String.t()
  def issue_access(subject), do: issue(subject, "access", @access_ttl)

  @spec issue_refresh(String.t()) :: String.t()
  def issue_refresh(subject), do: issue(subject, "refresh", @refresh_ttl)

  @doc """
  Verify signature, expiry, and the `type` claim ("access" | "refresh").
  A refresh token can never authenticate a protected request and vice versa.
  """
  @spec verify(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_token}
  def verify(token, expected_type) when is_binary(token) do
    with [header, payload, signature] <- String.split(token, "."),
         true <- Plug.Crypto.secure_compare(sign(header <> "." <> payload), signature),
         {:ok, raw} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"sub" => sub, "exp" => exp, "type" => ^expected_type} = claims}
         when is_binary(sub) and is_integer(exp) <- Jason.decode(raw),
         false <- expired?(exp) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp issue(subject, type, ttl) when is_binary(subject) and subject != "" do
    now = System.system_time(:second)

    payload =
      %{"sub" => subject, "iat" => now, "exp" => now + ttl, "type" => type}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signing_input = @header_b64 <> "." <> payload
    signing_input <> "." <> sign(signing_input)
  end

  defp sign(input) do
    :hmac
    |> :crypto.mac(:sha256, secret(), input)
    |> Base.url_encode64(padding: false)
  end

  defp expired?(exp), do: System.system_time(:second) >= exp

  defp secret do
    case Application.fetch_env!(:ssm, :jwt_secret) do
      secret when is_binary(secret) and secret != "" -> secret
    end
  end
end
