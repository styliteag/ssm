defmodule Ssm.FakeOIDCProvider do
  @moduledoc """
  In-process OIDC provider for tests (oidc-client-v1 §10): discovery, JWKS
  (ES256 key generated per run), and a token endpoint that returns an ID
  token signed with the claims registered for an authorization code.
  Served by Bandit on a free loopback port.
  """

  @behaviour Plug
  import Plug.Conn

  @kid "fake-key-1"
  @client_id "ssm-test"
  @client_secret "test-client-secret"

  def client_id, do: @client_id
  def client_secret, do: @client_secret

  @doc "Start the provider; returns `%{issuer, agent, key, other_key}`."
  def start do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    other = JOSE.JWK.generate_key({:ec, "P-256"})
    {:ok, agent} = Agent.start_link(fn -> %{codes: %{}, key: key, jwks_hits: 0} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}"
    Agent.update(agent, &Map.put(&1, :issuer, issuer))
    %{issuer: issuer, agent: agent, key: key, other_key: other, server: server}
  end

  @doc "How often the JWKS endpoint was fetched."
  def jwks_hits(%{agent: agent}), do: Agent.get(agent, & &1.jwks_hits)

  @doc "Register claims for an authorization code (nonce included by the caller)."
  def put_code(%{agent: agent}, code, claims, opts \\ []) do
    Agent.update(agent, fn s -> put_in(s, [:codes, code], {claims, opts}) end)
    code
  end

  @doc "Base ID-token claims for `sub`, merged with `extra` (nil values drop the key)."
  def claims(provider, sub, extra \\ %{}) do
    now = System.os_time(:second)

    %{
      "iss" => provider.issuer,
      "aud" => @client_id,
      "sub" => sub,
      "iat" => now,
      "exp" => now + 300,
      "name" => "Test User",
      "email" => "#{sub}@example.test"
    }
    |> Map.merge(extra)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Sign `claims` as a compact JWS with `key` (kid header set)."
  def sign(key, claims, alg \\ "ES256", kid \\ @kid) do
    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => alg, "kid" => kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "An unsecured (`alg: none`) token."
  def unsigned(claims) do
    enc = &Base.url_encode64(Jason.encode!(&1), padding: false)
    enc.(%{"alg" => "none", "typ" => "JWT"}) <> "." <> enc.(claims) <> "."
  end

  @impl true
  def init(agent), do: agent

  @impl true
  def call(%{path_info: [".well-known", "openid-configuration"]} = conn, agent) do
    issuer = Agent.get(agent, & &1.issuer)

    json(conn, %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/authorize",
      "token_endpoint" => issuer <> "/token",
      "jwks_uri" => issuer <> "/jwks",
      "response_types_supported" => ["code"],
      "scopes_supported" => ["openid", "profile", "email"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["ES256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_basic"],
      "code_challenge_methods_supported" => ["S256"],
      "grant_types_supported" => ["authorization_code"]
    })
  end

  def call(%{path_info: ["jwks"]} = conn, agent) do
    Agent.update(agent, &Map.update!(&1, :jwks_hits, fn n -> n + 1 end))
    key = Agent.get(agent, & &1.key)
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    json(conn, %{
      "keys" => [Map.merge(public, %{"kid" => @kid, "use" => "sig", "alg" => "ES256"})]
    })
  end

  def call(%{path_info: ["token"], method: "POST"} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    with true <- basic_auth_ok?(conn),
         {claims, opts} when is_map(claims) <- Agent.get(agent, & &1.codes[params["code"]]),
         true <- pkce_ok?(opts, params["code_verifier"]) do
      id_token = id_token(claims, opts, agent)

      json(conn, %{
        "access_token" => "at-" <> Base.url_encode64(:crypto.strong_rand_bytes(6)),
        "token_type" => "Bearer",
        "expires_in" => 60,
        "id_token" => id_token
      })
    else
      _ -> conn |> put_status(400) |> json(%{"error" => "invalid_grant"})
    end
  end

  def call(conn, _agent), do: send_resp(conn, 404, "")

  defp id_token(claims, opts, agent) do
    case {Keyword.get(opts, :sign_with), Keyword.get(opts, :kid, @kid)} do
      {:none, _} -> unsigned(claims)
      {nil, kid} -> sign(Agent.get(agent, & &1.key), claims, "ES256", kid)
      {key, kid} -> sign(key, claims, "ES256", kid)
    end
  end

  defp basic_auth_ok?(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] ->
        Base.decode64!(encoded) == "#{@client_id}:#{@client_secret}" or
          Base.decode64!(encoded) ==
            "#{URI.encode_www_form(@client_id)}:#{URI.encode_www_form(@client_secret)}"

      _ ->
        false
    end
  end

  defp pkce_ok?(opts, verifier) do
    case Keyword.get(opts, :challenge) do
      nil -> true
      challenge -> is_binary(verifier) and s256(verifier) == challenge
    end
  end

  defp s256(verifier), do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, Jason.encode!(data))
  end
end
