defmodule Ssm.Users do
  @moduledoc """
  Managed key owners and their public keys — the context behind
  `/api/v2/users` and `/api/v2/keys` (Users + Keys pages).
  """

  import Ecto.Query

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

  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(User, :count)

  @spec count_keys() :: non_neg_integer()
  def count_keys, do: Repo.aggregate(UserKey, :count)

  ## Keys

  @spec list_keys(keyword()) :: [UserKey.t()]
  def list_keys(opts \\ []) do
    query = from k in UserKey, order_by: k.id

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> where(query, [k], k.user_id == ^user_id)
      end

    Repo.all(query)
  end

  @spec get_key(integer()) :: UserKey.t() | nil
  def get_key(id), do: Repo.get(UserKey, id)

  @spec create_key(map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def create_key(attrs), do: %UserKey{} |> UserKey.changeset(attrs) |> Repo.insert()

  @spec update_key(UserKey.t(), map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def update_key(%UserKey{} = key, attrs), do: key |> UserKey.changeset(attrs) |> Repo.update()

  @spec delete_key(UserKey.t()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def delete_key(%UserKey{} = key), do: Repo.delete(key)

  @spec change_key(UserKey.t(), map()) :: Ecto.Changeset.t()
  def change_key(%UserKey{} = key, attrs \\ %{}), do: UserKey.changeset(key, attrs)
end
