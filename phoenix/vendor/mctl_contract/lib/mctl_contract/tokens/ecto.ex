defmodule MctlContract.Tokens.Ecto do
  @moduledoc """
  Default `MctlContract.TokenStore`: table `mctl_tokens` in the tool's repo
  (`MctlContract.Repo`). The tool's token prefix comes from
  `config :mctl_contract, token_prefix: "orbit_"` or the `prefix` option.
  """
  @behaviour MctlContract.TokenStore

  import Ecto.Query
  require Logger

  alias MctlContract.{Principal, TokenStore}
  alias MctlContract.Tokens.Token

  @touch_after 60
  @max_token 256

  @doc """
  Creates a token: `{:ok, token, plain}` (plain shown once) or
  `{:error, changeset}`. Options: `prefix`, `expires_at`, `binding`.
  """
  def create(name, scopes, opts \\ []) do
    prefix = Keyword.get_lazy(opts, :prefix, &default_prefix/0)
    plain = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    attrs = %{
      name: name,
      scopes: scopes,
      prefix: TokenStore.prefix(plain, prefix),
      secret_hash: TokenStore.hash(plain),
      expires_at: opts[:expires_at],
      binding: opts[:binding]
    }

    with {:ok, token} <- %Token{} |> Token.changeset(attrs) |> repo().insert() do
      {:ok, token, plain}
    end
  end

  @doc "All tokens by name."
  def list, do: repo().all(from t in Token, order_by: [asc: t.name, asc: t.id])

  @doc "Revokes the token `name` (kept as revoked)."
  def revoke(name) do
    now = DateTime.utc_now(:second)

    repo().update_all(from(t in Token, where: t.name == ^name and is_nil(t.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  @impl true
  def verify(plain) when is_binary(plain) and byte_size(plain) <= @max_token do
    case repo().get_by(Token, secret_hash: TokenStore.hash(plain)) do
      nil ->
        {:error, :invalid}

      token ->
        case Token.status(token, DateTime.utc_now()) do
          :active -> {:ok, principal(token)}
          other -> {:error, other}
        end
    end
  end

  def verify(_plain), do: {:error, :invalid}

  @impl true
  def touch(%Principal{id: id}, ip) do
    now = DateTime.utc_now(:second)
    cutoff = DateTime.add(now, -@touch_after)

    from(t in Token,
      where:
        t.id == ^id and
          (is_nil(t.last_used_at) or t.last_used_at < ^cutoff or t.last_used_ip != ^ip or
             is_nil(t.last_used_ip))
    )
    |> repo().update_all(set: [last_used_at: now, last_used_ip: ip])

    :ok
  end

  @impl true
  def ensure_service_token(name, sha256_hex, prefix, scopes) do
    case repo().get_by(Token, name: name) do
      %Token{secret_hash: ^sha256_hex} = token -> same_secret(token)
      existing -> install(existing || %Token{}, name, sha256_hex, prefix, scopes)
    end
  end

  # the same secret again (every boot): never undo a revocation or expiry
  defp same_secret(token) do
    case Token.status(token, DateTime.utc_now()) do
      :active -> :ok
      other -> {:error, other}
    end
  end

  defp install(token, name, sha256_hex, prefix, scopes) do
    attrs = %{
      name: name,
      secret_hash: sha256_hex,
      prefix: prefix,
      scopes: scopes,
      revoked_at: nil,
      expires_at: nil
    }

    token
    |> Token.changeset(attrs)
    |> repo().insert_or_update()
    |> case do
      {:ok, _token} ->
        Logger.info("mctl: service token #{name} installed (new secret)")
        :ok

      {:error, cs} ->
        {:error, cs.errors}
    end
  end

  @impl true
  def revoke_service_token(name) do
    now = DateTime.utc_now(:second)

    case repo().update_all(
           from(t in Token, where: t.name == ^name and is_nil(t.revoked_at)),
           set: [revoked_at: now, updated_at: now]
         ) do
      {0, _} -> :none
      {_n, _} -> :revoked
    end
  end

  @impl true
  def service_token_status(name) do
    case repo().get_by(Token, name: name) do
      nil ->
        nil

      token ->
        %{
          name: token.name,
          prefix: token.prefix,
          scopes: Token.scope_list(token),
          state: token |> Token.status(DateTime.utc_now()) |> Atom.to_string(),
          last_used_at: token.last_used_at,
          last_used_ip: token.last_used_ip,
          updated_at: token.updated_at
        }
    end
  end

  defp principal(token) do
    %Principal{
      id: token.id,
      name: token.name,
      prefix: token.prefix,
      scopes: Token.scope_list(token),
      binding: token.binding
    }
  end

  defp default_prefix, do: Application.get_env(:mctl_contract, :token_prefix, "mctl_")
  defp repo, do: MctlContract.Repo.get()
end
