defmodule Ssm.OIDC.Config do
  @moduledoc """
  OIDC client settings (oidc-client-v1 §2), read from the environment at
  boot by `load/0` and kept in `config :ssm, :oidc_config`. `nil` there
  means OIDC is off. Invalid settings log an error and leave OIDC off —
  never a crash. The client secret is only ever read from a file and is
  never logged.
  """

  require Logger

  @provider Ssm.OIDC.Provider

  defstruct issuer: nil,
            client_id: nil,
            client_secret: nil,
            role_claim: "orbit_role",
            customers_claim: "orbit_customers",
            role_map: [],
            login_label: "Login with SSO",
            session_max_hours: 8,
            local_login: :on,
            provider_opts: %{}

  @type t :: %__MODULE__{}

  @doc "The provider worker name."
  def provider, do: @provider

  @doc "Child spec of the provider worker (discovery + JWKS refresh) for `config`."
  @spec provider_child_spec(t()) :: Supervisor.child_spec()
  def provider_child_spec(%__MODULE__{} = config) do
    Oidcc.ProviderConfiguration.Worker.child_spec(%{
      issuer: config.issuer,
      name: @provider,
      provider_configuration_opts: config.provider_opts
    })
  end

  @doc "The active OIDC config, or `nil` when OIDC is off."
  @spec get() :: t() | nil
  def get, do: Application.get_env(:ssm, :oidc_config)

  @spec enabled?() :: boolean()
  def enabled?, do: get() != nil

  @doc "`:on | :admins_only | :off`, effective (see `from_env/1` for the safety rule)."
  @spec local_login() :: :on | :admins_only | :off
  def local_login, do: Application.get_env(:ssm, :local_login, :on)

  @doc "Read the environment and store the result in the application env."
  @spec load(map()) :: :ok
  def load(env \\ System.get_env()) do
    {config, local_login} = from_env(env)
    Application.put_env(:ssm, :oidc_config, config)
    Application.put_env(:ssm, :local_login, local_login)
  end

  @doc """
  Parse an env map into `{config | nil, local_login}`. `LOCAL_LOGIN=off`
  without working OIDC is downgraded to `:admins_only` (never lock
  everyone out).
  """
  @spec from_env(map()) :: {t() | nil, :on | :admins_only | :off}
  def from_env(env) do
    config = parse_oidc(env)
    {config, effective_local_login(parse_local_login(env), config)}
  end

  defp parse_oidc(%{"OIDC_ISSUER" => issuer} = env) when issuer != "" do
    with {:ok, client_id} <- required(env, "OIDC_CLIENT_ID"),
         {:ok, secret} <- read_secret(env["OIDC_CLIENT_SECRET_FILE"]) do
      %__MODULE__{
        issuer: String.trim_trailing(issuer, "/"),
        client_id: client_id,
        client_secret: secret,
        role_claim: env["OIDC_ROLE_CLAIM"] || "orbit_role",
        customers_claim: env["OIDC_CUSTOMERS_CLAIM"] || "orbit_customers",
        role_map: parse_role_map(env["OIDC_ROLE_MAP"]),
        login_label: blank_to(env["OIDC_LOGIN_LABEL"], "Login with SSO"),
        session_max_hours: parse_hours(env["OIDC_SESSION_MAX_HOURS"])
      }
    else
      {:error, reason} ->
        Logger.error("OIDC disabled: invalid configuration (#{reason})")
        nil
    end
  end

  defp parse_oidc(_env), do: nil

  defp required(env, key) do
    case env[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} missing"}
    end
  end

  defp read_secret(nil), do: {:error, "OIDC_CLIENT_SECRET_FILE missing"}
  defp read_secret(""), do: {:error, "OIDC_CLIENT_SECRET_FILE missing"}

  defp read_secret(path) do
    case File.read(path) do
      {:ok, content} ->
        warn_if_open(path)
        secret = String.trim(content)
        if secret == "", do: {:error, "OIDC_CLIENT_SECRET_FILE empty"}, else: {:ok, secret}

      {:error, reason} ->
        {:error, "OIDC_CLIENT_SECRET_FILE unreadable: #{reason}"}
    end
  end

  defp warn_if_open(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) != 0 ->
        Logger.warning("OIDC_CLIENT_SECRET_FILE is readable by group/other; tighten its mode")

      _ ->
        :ok
    end
  end

  @doc false
  def parse_role_map(nil), do: []

  def parse_role_map(text) do
    for pair <- String.split(text, ",", trim: true),
        [group, role] <- [String.split(pair, "=", parts: 2)],
        group = String.trim(group),
        group != "",
        do: {group, String.trim(role)}
  end

  defp parse_hours(nil), do: 8

  defp parse_hours(text) do
    case Integer.parse(text) do
      {hours, ""} when hours > 0 -> hours
      _ -> 8
    end
  end

  defp blank_to(value, default) when value in [nil, ""], do: default
  defp blank_to(value, _default), do: value

  defp parse_local_login(env) do
    case env["LOCAL_LOGIN"] do
      "admins_only" -> :admins_only
      "off" -> :off
      _ -> :on
    end
  end

  defp effective_local_login(:off, nil) do
    Logger.error("LOCAL_LOGIN=off without working OIDC: treating it as admins_only")
    :admins_only
  end

  defp effective_local_login(mode, _config), do: mode
end
