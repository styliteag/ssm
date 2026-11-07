defmodule MctlContract.Plug.Auth do
  @moduledoc false
  # Bearer authentication, `MctlContract.AuthHooks` and scope check. The
  # route's need comes from `conn.private.mctl_need`: :public, :any or a
  # scope name.
  import Plug.Conn

  alias MctlContract.{AuthHooks, Principal}
  alias MctlContract.Plug.Respond

  @max_token 256

  def call(%Plug.Conn{private: %{mctl_need: :public}} = conn, _opts), do: conn

  def call(conn, opts) do
    hooks = opts[:auth_hooks]

    case AuthHooks.before_auth(hooks, conn) do
      {:ok, conn} ->
        authenticate(conn, opts, hooks)

      {:halt, conn} ->
        halt(conn)

      {:error, retry_after} ->
        too_many(conn, retry_after, "too many failed authentication attempts")
    end
  end

  defp authenticate(conn, opts, hooks) do
    store = Keyword.fetch!(opts, :token_store)

    with {:ok, principal} <- verify(store, bearer(conn)),
         principal = %{principal | ip: ip(conn)},
         store.touch(principal, principal.ip),
         :ok <- AuthHooks.rate_limit(hooks, conn, principal) do
      conn |> assign(:mctl_principal, principal) |> check_scope(principal)
    else
      {:error, reason} when is_atom(reason) ->
        AuthHooks.on_auth_failure(hooks, conn, reason)
        Respond.error(conn, "unauthorized", "missing, invalid, expired or revoked token")

      {:error, retry_after} when is_integer(retry_after) ->
        too_many(conn, retry_after, "rate limit exceeded")
    end
  end

  defp too_many(conn, retry_after, message) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> Respond.error("rate_limited", message)
  end

  defp verify(_store, :missing), do: {:error, :missing}
  defp verify(_store, :invalid), do: {:error, :invalid}
  defp verify(store, token), do: store.verify(token)

  defp check_scope(conn, principal) do
    case conn.private[:mctl_need] do
      :any ->
        conn

      scope ->
        if Principal.has_scope?(principal, scope),
          do: conn,
          else: Respond.error(conn, "insufficient_scope", "this operation needs scope #{scope}")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        :missing

      ["Bearer " <> token] ->
        token = String.trim(token)
        if token != "" and byte_size(token) <= @max_token, do: token, else: :invalid

      _ ->
        :invalid
    end
  end

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
