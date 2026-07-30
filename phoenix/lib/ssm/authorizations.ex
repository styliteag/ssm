defmodule Ssm.Authorizations do
  @moduledoc """
  User↔host grants under a remote login — the context behind
  `/api/v2/authorizations` and the Authorizations page.
  """

  import Ecto.Query

  alias Ssm.Authorizations.Authorization
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

  @spec create_authorization(map()) :: {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(attrs),
    do: %Authorization{} |> Authorization.changeset(attrs) |> Repo.insert()

  @spec update_authorization(Authorization.t(), map()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def update_authorization(%Authorization{} = auth, attrs),
    do: auth |> Authorization.changeset(attrs) |> Repo.update()

  @spec delete_authorization(Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def delete_authorization(%Authorization{} = auth), do: Repo.delete(auth)

  @spec change_authorization(Authorization.t(), map()) :: Ecto.Changeset.t()
  def change_authorization(%Authorization{} = auth, attrs \\ %{}),
    do: Authorization.changeset(auth, attrs)
end
