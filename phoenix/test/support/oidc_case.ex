defmodule SsmWeb.OIDCCase do
  @moduledoc """
  Case template for OIDC tests: starts the fake provider, points
  `Ssm.OIDC.Config` at it, starts the oidcc provider worker, and offers
  `sso_login/3` to run the login → callback round trip.
  """

  use ExUnit.CaseTemplate

  alias Ssm.FakeOIDCProvider, as: Fake
  alias Ssm.OIDC.Config

  require Phoenix.ConnTest

  @endpoint SsmWeb.Endpoint

  using do
    quote do
      @endpoint SsmWeb.Endpoint
      use SsmWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import SsmWeb.ConnCase
      import SsmWeb.OIDCCase
      alias Ssm.FakeOIDCProvider, as: Fake
    end
  end

  setup tags do
    Ssm.DataCase.setup_sandbox(tags)
    Ssm.RateLimit.reset()
    provider = Fake.start(end_session: tags[:end_session] != false)

    config = %Config{
      issuer: provider.issuer,
      client_id: Fake.client_id(),
      client_secret: Fake.client_secret(),
      provider_opts: %{quirks: %{allow_unsafe_http: true}}
    }

    prev = {Application.get_env(:ssm, :oidc_config), Application.get_env(:ssm, :local_login)}
    Application.put_env(:ssm, :oidc_config, config)
    Application.put_env(:ssm, :local_login, :on)

    ExUnit.Callbacks.on_exit(fn ->
      {c, l} = prev
      Application.put_env(:ssm, :oidc_config, c)
      Application.put_env(:ssm, :local_login, l)
    end)

    ExUnit.Callbacks.start_supervised!(Config.provider_child_spec(config))
    wait_for_provider()
    {:ok, conn: Phoenix.ConnTest.build_conn(), provider: provider, config: config}
  end

  defp wait_for_provider(tries \\ 50) do
    Oidcc.ProviderConfiguration.Worker.get_provider_configuration(Config.provider())
    :ok
  catch
    _, _ when tries > 0 ->
      Process.sleep(50)
      wait_for_provider(tries - 1)
  end

  @doc "Replace the active OIDC config fields (tests)."
  def put_config(changes) do
    Application.put_env(:ssm, :oidc_config, struct!(Config.get(), changes))
  end

  @doc "GET /auth/oidc/login; returns the conn and the authorize URL's query params."
  def start_login(conn) do
    conn = Phoenix.ConnTest.get(conn, "/auth/oidc/login")
    "http" <> _ = location = Phoenix.ConnTest.redirected_to(conn)
    {conn, URI.decode_query(URI.parse(location).query)}
  end

  @doc """
  Full round trip. `claims` are merged over the base claims (nil drops a
  key); `opts`: `:sub`, `:state` (override), `:nonce` (override),
  `:sign_with`. Returns the callback conn.
  """
  def sso_login(conn, provider, claims \\ %{}, opts \\ []) do
    {conn, q} = start_login(conn)
    nonce = Keyword.get(opts, :nonce, q["nonce"])
    all = Fake.claims(provider, Keyword.get(opts, :sub, "sub-1"), Map.put(claims, "nonce", nonce))
    code = "code-" <> Integer.to_string(System.unique_integer([:positive]))

    Fake.put_code(provider, code, all,
      challenge: q["code_challenge"],
      sign_with: Keyword.get(opts, :sign_with),
      kid: Keyword.get(opts, :kid, "fake-key-1")
    )

    state = Keyword.get(opts, :state, q["state"])
    Phoenix.ConnTest.get(conn, "/auth/oidc/callback", %{"code" => code, "state" => state})
  end
end
