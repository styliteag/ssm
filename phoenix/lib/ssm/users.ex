defmodule Ssm.Users do
  @moduledoc """
  Managed key owners and their public keys — the context behind
  `/api/v2/users` and `/api/v2/keys` (Users + Keys pages).
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

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs), do: user |> User.changeset(attrs) |> Repo.update()

  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user), do: Repo.delete(user)

  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc "Every user with their key and authorization counts (Users page rows)."
  @spec list_users_with_counts() :: [
          %{user: User.t(), key_count: non_neg_integer(), authorization_count: non_neg_integer()}
        ]
  def list_users_with_counts do
    key_counts = per_user_counts(UserKey)
    auth_counts = per_user_counts(Authorization)

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

  @spec create_key(map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def create_key(attrs), do: %UserKey{} |> UserKey.changeset(attrs) |> Repo.insert()

  @spec update_key(UserKey.t(), map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def update_key(%UserKey{} = key, attrs), do: key |> UserKey.changeset(attrs) |> Repo.update()

  @spec delete_key(UserKey.t()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def delete_key(%UserKey{} = key), do: Repo.delete(key)

  @spec change_key(UserKey.t(), map()) :: Ecto.Changeset.t()
  def change_key(%UserKey{} = key, attrs \\ %{}), do: UserKey.changeset(key, attrs)
end
