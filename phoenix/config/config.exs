# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# mctl contract v1 (/api/mctl/v1): the library's Ecto stores (tokens, jobs,
# idempotency) live in ssm's repo; service tokens carry the `ssm_` prefix.
config :mctl_contract, repo: Ssm.Repo, token_prefix: "ssm_"

# mctl create_host (onboarding v2 §4): after handing out ssm's public key the
# job retries the SSH login with exponential backoff until the key is
# authorized on the host, for at most `timeout_ms`.
config :ssm, :mctl_login_wait,
  timeout_ms: 600_000,
  # before the first login: mctl authorizes ssm's key in that time
  initial_wait_ms: 5_000,
  first_delay_ms: 2_000,
  max_delay_ms: 30_000

# IANA zones for the viewer's time zone (SsmWeb.TimeZone). Storage and API stay UTC.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :ssm,
  ecto_repos: [Ssm.Repo],
  generators: [timestamp_type: :utc_datetime]

# SQLite: a write waits up to 15 s for another writer's lock (IMMEDIATE
# transactions, Ssm.Grants.transaction/1) instead of failing "Database busy"
# after the driver's default 2 s. Every environment (runtime.exs adds the
# prod path only).
config :ssm, Ssm.Repo, busy_timeout: 15_000

# Configure the endpoint
config :ssm, SsmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SsmWeb.ErrorHTML, json: SsmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ssm.PubSub,
  live_view: [signing_salt: "vQeFfaG/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ssm: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  ssm: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
