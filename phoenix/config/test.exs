import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ssm, Ssm.Repo,
  database: Path.expand("../ssm_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ssm, SsmWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # Test-only, deliberately low-entropy (secret scanner + not a secret).
  secret_key_base: "ssm-test-only-secret-key-base-0000000000-1111111111-2222222222-33333333",
  server: false

# Test-only, deliberately low-entropy (secret scanner + not a secret).
config :ssm, jwt_secret: "ssm-test-only-jwt-secret-0000000000-1111111111"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Fast bcrypt in tests (never in prod)
config :bcrypt_elixir, log_rounds: 1

# SSH: never start the real client in tests; the facade resolves to the mock
config :ssm, start_ssh_client: false
config :ssm, :ssh_client, Ssm.Ssh.MockClient
