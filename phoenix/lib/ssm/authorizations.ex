defmodule Ssm.Authorizations do
  @moduledoc """
  User↔host grants under a remote login — the context behind
  `/api/v2/authorizations` and the Authorizations page.
  """

  import Ecto.Query

  alias Ssm.Authorizations.{Authorization, ManagedLogin, Options}
  alias Ssm.Repo

  @spec list_authorizations(keyword()) :: [Authorization.t()]
  def list_authorizations(opts \\ []) do
    query = from a in Authorization, order_by: a.id, preload: [:user, :host]

    query =
      Enum.reduce(opts, query, fn
        {:host_id, host_id}, q -> where(q, [a], a.host_id == ^host_id)
        {:user_id, user_id}, q -> where(q, [a], a.user_id == ^user_id)
        _other, q -> q
      end)

    Repo.all(query)
  end

  @spec count_authorizations() :: non_neg_integer()
  def count_authorizations, do: Repo.aggregate(Authorization, :count)

  @spec get_authorization(integer()) :: Authorization.t() | nil
  def get_authorization(id), do: Repo.get(Authorization, id)

  @doc "True when a grant with exactly this (user, host, login) exists."
  @spec exists?(integer(), integer(), String.t()) :: boolean()
  def exists?(user_id, host_id, login) do
    Repo.exists?(
      from a in Authorization,
        where: a.user_id == ^user_id and a.host_id == ^host_id and a.login == ^login
    )
  end

  @doc "Fetch the grant for exactly this (user, host, login), or nil."
  @spec get_by_grant(integer(), integer(), String.t()) :: Authorization.t() | nil
  def get_by_grant(user_id, host_id, login),
    do: Repo.get_by(Authorization, user_id: user_id, host_id: host_id, login: login)

  @doc """
  The subset of `user_ids × host_ids` pairs that already hold a grant under
  `login`, as a MapSet of `{user_id, host_id}` tuples.
  """
  @spec existing_grant_pairs([integer()], [integer()], String.t()) :: MapSet.t()
  def existing_grant_pairs(user_ids, host_ids, login) do
    from(a in Authorization,
      where: a.user_id in ^user_ids and a.host_id in ^host_ids and a.login == ^login,
      select: {a.user_id, a.host_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Grant `login` (with optional `options`) to every user in `user_ids` on every
  host in `host_ids`. Pairs that already hold an identical (user, host, login)
  grant are skipped. Runs in one transaction: any changeset failure rolls the
  whole batch back and returns `{:error, changeset}`.

  Returns `{:ok, %{created: [auth], skipped: n}}` on success.
  """
  @spec bulk_grant([integer()], [integer()], String.t(), String.t() | nil) ::
          {:ok, %{created: [Authorization.t()], skipped: non_neg_integer()}}
          | {:error, Ecto.Changeset.t()}
  def bulk_grant(user_ids, host_ids, login, options \\ nil) do
    existing = existing_grant_pairs(user_ids, host_ids, login)
    pairs = for user_id <- user_ids, host_id <- host_ids, do: {user_id, host_id}
    new_pairs = Enum.reject(pairs, &MapSet.member?(existing, &1))

    Repo.transaction(fn ->
      created =
        Enum.map(new_pairs, fn {user_id, host_id} ->
          attrs = %{user_id: user_id, host_id: host_id, login: login, options: options}

          case create_authorization(attrs) do
            {:ok, auth} -> auth
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      %{created: created, skipped: length(pairs) - length(new_pairs)}
    end)
  end

  @doc """
  Create a grant and record its login as managed (`managed_logins`) in the
  same transaction — every creation path (UI, `/api/v2`, `bulk_grant/4`,
  key assignment, diff page "Allow") goes through here.
  """
  @spec create_authorization(map()) :: {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(attrs),
    do: %Authorization{} |> Authorization.changeset(attrs) |> write_managed(&Repo.insert/1)

  @doc "Update a grant; a new host/login pair is recorded as managed too."
  @spec update_authorization(Authorization.t(), map()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def update_authorization(%Authorization{} = auth, attrs),
    do: auth |> Authorization.changeset(attrs) |> write_managed(&Repo.update/1)

  # an invalid changeset never reaches the DB: no transaction, so a caller's
  # outer transaction is not rolled back by a plain validation error
  defp write_managed(%Ecto.Changeset{valid?: false} = changeset, write), do: write.(changeset)

  defp write_managed(changeset, write) do
    Repo.transaction(fn ->
      case write.(changeset) do
        {:ok, auth} -> tap(auth, &record_managed_login(&1.host_id, &1.login))
        {:error, failed} -> Repo.rollback(failed)
      end
    end)
  end

  @doc """
  Mark `login` on `host_id` as managed by ssm (idempotent). A sync keeps
  writing a managed login's file even after its last grant is gone.
  """
  @spec record_managed_login(integer(), String.t()) :: :ok
  def record_managed_login(host_id, login) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all(ManagedLogin, [%{host_id: host_id, login: login, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:host_id, :login]
    )

    :ok
  end

  @doc """
  Stored grants whose `options` fail today's rules (`Options.validate/1`),
  e.g. written before the options were validated: `%{authorization_id, host,
  login, user, options, reason}` sorted by id — rows of
  `Ssm.Release.invalid_stored_rows/0` (`table: "authorization"`). A sync keeps the host's line
  of such a key instead of writing it; fix or clear the options.
  """
  @spec invalid_stored_options() :: [map()]
  def invalid_stored_options do
    from(a in Authorization,
      where: not is_nil(a.options) and a.options != "",
      order_by: a.id,
      preload: [:host, :user]
    )
    |> Repo.all()
    |> Enum.flat_map(fn auth ->
      case Options.validate(auth.options) do
        :ok -> []
        {:error, reason} -> [invalid_row(auth, reason)]
      end
    end)
  end

  defp invalid_row(auth, reason) do
    %{
      table: "authorization",
      id: auth.id,
      field: "options",
      host: auth.host && auth.host.name,
      login: auth.login,
      user: auth.user && auth.user.username,
      options: auth.options,
      reason: reason
    }
  end

  @doc "The managed logins of a host, sorted."
  @spec managed_logins(integer()) :: [String.t()]
  def managed_logins(host_id) do
    Repo.all(
      from m in ManagedLogin, where: m.host_id == ^host_id, order_by: m.login, select: m.login
    )
  end

  @spec delete_authorization(Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def delete_authorization(%Authorization{} = auth), do: Repo.delete(auth)

  @spec change_authorization(Authorization.t(), map()) :: Ecto.Changeset.t()
  def change_authorization(%Authorization{} = auth, attrs \\ %{}),
    do: Authorization.changeset(auth, attrs)
end
