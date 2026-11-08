defmodule Ssm.Users do
  @moduledoc """
  Managed key owners and their public keys — the context behind
  `/api/v2/users` and `/api/v2/keys` (Users + Keys pages).

  The SSH user catalog is readable in full by every web user (ADR-0012 §3).
  Writes that take an `Ssm.Scope` first serve the web UI: they change a
  user or its keys only when the user is `writable?/2` – every one of its
  authorizations is on a host in scope, because a key change lands on every
  host of that user. Otherwise `{:error, :out_of_scope}`. The scope-less
  writes stay global (`/api/v2`, mctl contract).
  """

  import Ecto.Query

  alias Ssm.Authorizations.Authorization
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  ## Users

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: u.username)

  @spec get_user(integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  May a user with `scope` change this SSH user (or user id) and its keys?
  True when none of its authorizations is on a host outside the scope (a
  user without authorizations is writable). Grants of deleted hosts count
  as outside.
  """
  @spec writable?(Ssm.Scope.t(), User.t() | integer()) :: boolean()
  def writable?(%Ssm.Scope{} = scope, %User{id: id}), do: writable?(scope, id)

  def writable?(%Ssm.Scope{} = scope, user_id) when is_integer(user_id) do
    Ssm.Scope.global?(scope) or
      not Repo.exists?(
        from a in Authorization,
          where: a.user_id == ^user_id and a.host_id not in subquery(Ssm.Scope.host_ids(scope))
      )
  end

  def writable?(_scope, _user_id), do: false

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs), do: user |> User.changeset(attrs) |> Repo.update()

  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user), do: Repo.delete(user)

  @doc "`update_user/2` for a web user: only a `writable?/2` user."
  @spec update_user(Ssm.Scope.t(), User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def update_user(%Ssm.Scope{} = scope, %User{} = user, attrs),
    do: if(writable?(scope, user), do: update_user(user, attrs), else: {:error, :out_of_scope})

  @doc "`delete_user/1` for a web user: only a `writable?/2` user."
  @spec delete_user(Ssm.Scope.t(), User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def delete_user(%Ssm.Scope{} = scope, %User{} = user),
    do: if(writable?(scope, user), do: delete_user(user), else: {:error, :out_of_scope})

  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc """
  Every user with their key count and the count of their authorizations on
  hosts in `scope` (Users page rows; the SSH user catalog is readable in
  full, ADR-0012 §3, host data is not).
  """
  @spec list_users_with_counts(Ssm.Scope.t()) :: [
          %{user: User.t(), key_count: non_neg_integer(), authorization_count: non_neg_integer()}
        ]
  def list_users_with_counts(%Ssm.Scope{} = scope \\ Ssm.Scope.global()) do
    key_counts = per_user_counts(UserKey)
    auth_counts = per_user_counts(Ssm.Scope.filter(Authorization, scope))

    Enum.map(list_users(), fn user ->
      %{
        user: user,
        key_count: Map.get(key_counts, user.id, 0),
        authorization_count: Map.get(auth_counts, user.id, 0)
      }
    end)
  end

  defp per_user_counts(schema) do
    from(r in schema, group_by: r.user_id, select: {r.user_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(User, :count)

  @spec count_keys() :: non_neg_integer()
  def count_keys, do: Repo.aggregate(UserKey, :count)

  ## Keys

  @spec list_keys(keyword()) :: [UserKey.t()]
  def list_keys(opts \\ []) do
    query = from k in UserKey, order_by: k.id, preload: [:user]

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> where(query, [k], k.user_id == ^user_id)
      end

    Repo.all(query)
  end

  @spec get_key(integer()) :: UserKey.t() | nil
  def get_key(id), do: UserKey |> Repo.get(id) |> Repo.preload(:user)

  @doc "Look a key up by its base64 material (unique) — diff owner resolution."
  @spec get_key_by_base64(String.t()) :: UserKey.t() | nil
  def get_key_by_base64(base64) do
    UserKey |> Repo.get_by(key_base64: base64) |> Repo.preload(:user)
  end

  @doc """
  Stored keys with control characters (`Ssm.ControlChars`) in type,
  material, comment or extra comment — rows of
  `Ssm.Release.invalid_stored_rows/0` (`table: "user_key"`, one per field).
  """
  @spec invalid_stored_keys() :: [map()]
  def invalid_stored_keys do
    from(k in UserKey, order_by: k.id, preload: :user)
    |> Repo.all()
    |> Enum.flat_map(fn key ->
      for field <- [:key_type, :key_base64, :name, :extra_comment],
          Ssm.ControlChars.present?(Map.get(key, field)) do
        %{
          table: "user_key",
          id: key.id,
          field: Atom.to_string(field),
          user: key.user && key.user.username,
          host: nil,
          login: nil,
          reason: "must not contain control characters"
        }
      end
    end)
  end

  @spec create_key(map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def create_key(attrs), do: %UserKey{} |> UserKey.changeset(attrs) |> Repo.insert()

  @spec update_key(UserKey.t(), map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def update_key(%UserKey{} = key, attrs), do: key |> UserKey.changeset(attrs) |> Repo.update()

  @spec delete_key(UserKey.t()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def delete_key(%UserKey{} = key), do: Repo.delete(key)

  @doc "`create_key/1` for a web user: the owner must be `writable?/2`."
  @spec create_key(Ssm.Scope.t(), map()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def create_key(%Ssm.Scope{} = scope, attrs) do
    owner = %UserKey{} |> UserKey.changeset(attrs) |> Ecto.Changeset.get_field(:user_id)

    if is_nil(owner) or writable?(scope, owner),
      do: create_key(attrs),
      else: {:error, :out_of_scope}
  end

  @doc "`update_key/2` for a web user: the old and the new owner must be `writable?/2`."
  @spec update_key(Ssm.Scope.t(), UserKey.t(), map()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def update_key(%Ssm.Scope{} = scope, %UserKey{} = key, attrs) do
    new_owner = key |> UserKey.changeset(attrs) |> Ecto.Changeset.get_field(:user_id)

    if writable?(scope, key.user_id) and writable?(scope, new_owner),
      do: update_key(key, attrs),
      else: {:error, :out_of_scope}
  end

  @doc "`delete_key/1` for a web user: the owner must be `writable?/2`."
  @spec delete_key(Ssm.Scope.t(), UserKey.t()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def delete_key(%Ssm.Scope{} = scope, %UserKey{} = key),
    do: if(writable?(scope, key.user_id), do: delete_key(key), else: {:error, :out_of_scope})

  @spec change_key(UserKey.t(), map()) :: Ecto.Changeset.t()
  def change_key(%UserKey{} = key, attrs \\ %{}), do: UserKey.changeset(key, attrs)
end
