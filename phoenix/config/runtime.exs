import Config

# Runtime configuration, evaluated at boot for every environment (including
# releases). Env-var names and defaults mirror the python stack's config.py
# so operators can switch stacks without touching their environment:
#   DATABASE_URL (sqlite:///relative.db | sqlite:////abs/path.db)
#   HTPASSWD, SSH_KEY, SSH_KEY_PASSPHRASE, SSH_TIMEOUT,
#   SSH_CHECK_SCHEDULE, SSH_UPDATE_SCHEDULE,
#   JWT_SECRET (fallback SESSION_KEY), LOGLEVEL, PORT, LISTEN
# Phoenix-native vars (DATABASE_PATH, SECRET_KEY_BASE, PHX_HOST) win when set.

if System.get_env("PHX_SERVER") do
  config :ssm, SsmWeb.Endpoint, server: true
end

# --- shared: SSH + htpasswd (all environments) ------------------------------

config :ssm, :htpasswd_path, System.get_env("HTPASSWD", ".htpasswd")

config :ssm, :ssh,
  key_file: System.get_env("SSH_KEY", "keys/id_ssm"),
  key_passphrase: System.get_env("SSH_KEY_PASSPHRASE"),
  timeout_seconds: String.to_integer(System.get_env("SSH_TIMEOUT", "120")),
  check_schedule: System.get_env("SSH_CHECK_SCHEDULE"),
  update_schedule: System.get_env("SSH_UPDATE_SCHEDULE")

# LOGLEVEL accepts RUST_LOG-style directives ("info", "ssm=debug,actix=warn");
# the most verbose known level wins, unknown tokens fall back to :info —
# ported from config.py rust_log_to_python_level.
loglevel_rank = %{
  "trace" => 0,
  "debug" => 0,
  "info" => 1,
  "warn" => 2,
  "warning" => 2,
  "error" => 3,
  "off" => 4
}

loglevel_atom = %{0 => :debug, 1 => :info, 2 => :warning, 3 => :error, 4 => :emergency}

if raw = System.get_env("LOGLEVEL") do
  ranks =
    raw
    |> String.split(",")
    |> Enum.map(fn part ->
      token = part |> String.trim() |> String.downcase()

      token =
        case String.split(token, "=", parts: 2) do
          [_target, level] -> level
          [level] -> level
        end

      Map.get(loglevel_rank, token)
    end)
    |> Enum.reject(&is_nil/1)

  if ranks != [] do
    config :logger, level: Map.fetch!(loglevel_atom, Enum.min(ranks))
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :ssm, SsmWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/ssm_web/router\.ex$"E,
        ~r"lib/ssm_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # DATABASE_PATH (plain path) wins; else parse the python-style DATABASE_URL.
  database_path =
    System.get_env("DATABASE_PATH") ||
      case System.get_env("DATABASE_URL", "sqlite:///ssm.db") do
        "sqlite+aiosqlite:///" <> rest ->
          rest

        "sqlite:///" <> rest ->
          rest

        other ->
          raise """
          unsupported DATABASE_URL #{inspect(other)} — the Elixir stack expects
          sqlite:///relative.db or sqlite:////absolute/path.db (or set DATABASE_PATH).
          """
      end

  config :ssm, Ssm.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # SECRET_KEY_BASE wins; otherwise derive deterministic key material from the
  # python stack's JWT_SECRET / SESSION_KEY so operators need no new secret.
  # Length is checked at boot: a too-short value boots fine and keeps the
  # health endpoint green while every real page 500s on the session store
  # ("cookie store expects at least 64 bytes") — fail loudly instead.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        case System.get_env("JWT_SECRET") || System.get_env("SESSION_KEY") do
          nil ->
            raise """
            environment variable SECRET_KEY_BASE (or JWT_SECRET / SESSION_KEY)
            is missing. Generate one with: openssl rand -base64 48
            """

          jwt_secret ->
            :crypto.hash(:sha512, "ssm-secret-key-base:" <> jwt_secret) |> Base.encode64()
        end

      explicit when byte_size(explicit) < 64 ->
        raise """
        SECRET_KEY_BASE must be at least 64 bytes, got #{byte_size(explicit)}.
        Generate one with: openssl rand -base64 48
        """

      explicit ->
        explicit
    end

  # API bearer tokens sign with the same secret as the python stack so
  # existing clients keep working; SECRET_KEY_BASE-only deployments still get
  # a working (but python-incompatible) signing key.
  config :ssm,
         :jwt_secret,
         System.get_env("JWT_SECRET") || System.get_env("SESSION_KEY") || secret_key_base

  host = System.get_env("PHX_HOST") || "localhost"

  # LISTEN mirrors the python stack (default "::" = all interfaces, v4+v6).
  listen_ip =
    case System.get_env("LISTEN", "::") |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> ip
      {:error, _} -> raise "LISTEN must be an IP address, got: #{System.get_env("LISTEN")}"
    end

  config :ssm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ssm, SsmWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Operators reach the app by IP or arbitrary hostname (no PHX_HOST set in
    # the usual LAN deployment). :conn checks the WebSocket origin against the
    # request's own host header instead of a fixed allowlist.
    check_origin: :conn,
    http: [
      ip: listen_ip,
      port: String.to_integer(System.get_env("PORT", "8000"))
    ],
    secret_key_base: secret_key_base
else
  config :ssm, SsmWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end
