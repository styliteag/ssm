defmodule MctlContract.AuthHooks do
  @moduledoc """
  Optional hooks around authentication, so a tool can plug in its own
  limits and audit (Plug option `auth_hooks: MyApp.MctlAuthHooks`). Every
  callback is optional; without the option nothing runs. Hooks do not run
  for public routes (`/openapi.json`).

  Order per request: `before_auth/1` → token check → on failure
  `on_auth_failure/2` and 401 → `touch` → `rate_limit/2` → scope check.

    * `before_auth(conn)` – e.g. a per-IP limit of failed attempts.
      `{:ok, conn}` continues; `{:error, retry_after}` answers
      `429 rate_limited` with `Retry-After`; `{:halt, conn}` keeps a
      response the hook already sent.
    * `on_auth_failure(conn, reason)` – audit and failure counting;
      `reason` is `:missing`, `:invalid`, `:expired` or `:revoked`. The
      return value is ignored.
    * `rate_limit(conn, principal)` – per-token limit: `:ok` or
      `{:error, retry_after}` (`429 rate_limited` with `Retry-After`).

  A missing scope (403) is not an authentication failure.
  """
  alias MctlContract.Principal

  @type retry_after :: pos_integer()

  @callback before_auth(Plug.Conn.t()) ::
              {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()} | {:error, retry_after()}
  @callback on_auth_failure(Plug.Conn.t(), :missing | :invalid | :expired | :revoked) :: any()
  @callback rate_limit(Plug.Conn.t(), Principal.t()) :: :ok | {:error, retry_after()}

  @optional_callbacks before_auth: 1, on_auth_failure: 2, rate_limit: 2

  @doc false
  def before_auth(nil, conn), do: {:ok, conn}

  def before_auth(hooks, conn),
    do: if(exported?(hooks, :before_auth, 1), do: hooks.before_auth(conn), else: {:ok, conn})

  @doc false
  def on_auth_failure(nil, _conn, _reason), do: :ok

  def on_auth_failure(hooks, conn, reason) do
    if exported?(hooks, :on_auth_failure, 2), do: hooks.on_auth_failure(conn, reason)
    :ok
  end

  @doc false
  def rate_limit(nil, _conn, _principal), do: :ok

  def rate_limit(hooks, conn, principal),
    do: if(exported?(hooks, :rate_limit, 2), do: hooks.rate_limit(conn, principal), else: :ok)

  defp exported?(mod, fun, arity) do
    Code.ensure_loaded(mod)
    function_exported?(mod, fun, arity)
  end
end
