defmodule SsmWeb.Plugs.ServiceTokenAuth do
  @moduledoc """
  Bearer authentication with ssm's `ssm_` service tokens outside the mctl
  contract path, for `GET /api/export/checkmk`. Same checks, limits and
  audit as `/api/mctl/v1` (the contract library's auth step with
  `SsmWeb.MctlAuthHooks`): 401 `unauthorized` for a missing, invalid,
  expired or revoked token, 403 `insufficient_scope` without the needed
  scope, 429 `rate_limited` with `Retry-After`; the error body is the
  contract's `{"error": {code, message}}`.

  Option `:scope` (default `"read"`).
  """

  @behaviour Plug

  alias MctlContract.Tokens.Ecto, as: Store

  @impl true
  def init(opts), do: Keyword.get(opts, :scope, "read")

  @impl true
  def call(conn, scope) do
    conn
    |> Plug.Conn.put_private(:mctl_need, scope)
    |> MctlContract.Plug.Auth.call(token_store: Store, auth_hooks: SsmWeb.MctlAuthHooks)
  end
end
