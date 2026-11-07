defmodule MctlContract.Bootstrap do
  @moduledoc """
  The env-managed service token `mission-control-env`, kept at boot.

  * `MCTL_TOKEN_FILE` names a file holding the full token (e.g. a Docker
    secret); `MCTL_TOKEN_SCOPES` (default `read,setup,commands`) limits its
    scopes. Only the SHA-256 and the shown prefix (tool prefix + 4
    characters) reach the token store.
  * A new secret in the file rotates the token. The same secret never
    undoes a revocation or an expiry: a revoked leaked token stays revoked
    (`{:error, :revoked}`, logged as a warning).
  * Without `MCTL_TOKEN_FILE` an active `mission-control-env` token is
    revoked (`:revoked`), if the store implements `revoke_service_token/1`.
    Tokens created in the tool's UI use another name and are not touched.
  * A file readable by group or others is installed with a warning.

  The token never appears in logs or return values. Call it from the
  tool's `Application.start/2`, after the repo started:

      MctlContract.Bootstrap.ensure_service_token(MyApp.MctlTokens, prefix: "omon_")

  Options: `prefix` (the tool's token prefix; a token without it is
  refused), `name` (default `mission-control-env`), `env` (default
  `System.get_env/0`, for tests).
  """
  import Bitwise
  require Logger

  alias MctlContract.TokenStore

  @name "mission-control-env"
  @default_scopes "read,setup,commands"
  @min_secret 43

  @doc "Name of the env-managed service token."
  def name, do: @name

  @spec ensure_service_token(module(), keyword()) ::
          :ok | :skipped | :revoked | {:error, term()}
  def ensure_service_token(token_store, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    name = Keyword.get(opts, :name, @name)

    case env["MCTL_TOKEN_FILE"] do
      path when path in [nil, ""] ->
        revoke(token_store, name)

      path ->
        result = install(token_store, name, path, env, opts)
        log(result, name, path)
        result
    end
  end

  defp revoke(token_store, name) do
    Code.ensure_loaded(token_store)

    with true <- function_exported?(token_store, :revoke_service_token, 1),
         :revoked <- token_store.revoke_service_token(name) do
      Logger.warning("mctl: MCTL_TOKEN_FILE is unset, service token #{name} revoked")
      :revoked
    else
      _ -> :skipped
    end
  end

  defp install(token_store, name, path, env, opts) do
    prefix = opts[:prefix]

    with {:ok, token} <- read(path, prefix),
         {:ok, scopes} <- scopes(env["MCTL_TOKEN_SCOPES"]) do
      token_store.ensure_service_token(
        name,
        TokenStore.hash(token),
        TokenStore.prefix(token, prefix),
        scopes
      )
    end
  end

  defp read(path, prefix) do
    case File.read(path) do
      {:ok, content} ->
        warn_mode(path)
        token = String.trim(content)

        with :ok <- check_prefix(token, prefix) do
          if String.length(token) - String.length(prefix || "") >= @min_secret,
            do: {:ok, token},
            else: {:error, :token_too_short}
        end

      {:error, reason} ->
        {:error, {:token_file, reason}}
    end
  end

  defp warn_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& 0o077) != 0 ->
        Logger.warning(
          "mctl: MCTL_TOKEN_FILE #{path} is readable by group or other users " <>
            "(mode #{Integer.to_string(mode &&& 0o777, 8)}); restrict it to the owner"
        )

      _ ->
        :ok
    end
  end

  defp check_prefix(token, nil), do: if(token == "", do: {:error, :token_too_short}, else: :ok)

  defp check_prefix(token, prefix) do
    cond do
      token == "" -> {:error, :token_too_short}
      String.starts_with?(token, prefix) -> :ok
      true -> {:error, {:wrong_prefix, prefix}}
    end
  end

  defp scopes(value) do
    scopes =
      (value || @default_scopes)
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case Enum.reject(scopes, &(&1 in TokenStore.scopes())) do
      [] when scopes != [] -> {:ok, scopes}
      [] -> {:error, :no_scopes}
      unknown -> {:error, {:unknown_scopes, unknown}}
    end
  end

  defp log(:ok, name, path),
    do: Logger.info("mctl: service token #{name} from #{path} is active")

  defp log({:error, state}, name, path) when state in [:revoked, :expired] do
    Logger.warning(
      "mctl: MCTL_TOKEN_FILE holds a #{state} token (#{name}, #{path}); " <>
        "put a new secret into the file to replace it"
    )
  end

  defp log({:error, reason}, name, path),
    do: Logger.error("mctl: service token #{name} from #{path} not installed: #{inspect(reason)}")
end
