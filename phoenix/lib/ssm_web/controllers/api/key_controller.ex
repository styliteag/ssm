defmodule SsmWeb.Api.KeyController do
  @moduledoc """
  `/api/v2/keys` CRUD — python `api/v2/keys.py`: `?user_id=` list filter,
  owner existence check on create (404 USER_NOT_FOUND), PATCH restricted to
  `name`/`extra_comment`.
  """

  use SsmWeb, :controller

  import Ecto.Query

  alias Ssm.Repo
  alias Ssm.Users
  alias Ssm.Users.UserKey
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @create_spec [
    user_id: [type: :integer, required: true],
    key_type: [type: :string, required: true, min_len: 1, max_len: 32],
    key_base64: [type: :string, required: true, min_len: 16, max_len: 8192],
    name: [type: :string, nilable: true, max_len: 128],
    extra_comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @update_spec [
    name: [type: :string, nilable: true, max_len: 128],
    extra_comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @list_spec [
    user_id: [type: :integer]
  ]

  def index(conn, params) do
    case Params.validate_partial(params, @list_spec) do
      {:ok, filters} ->
        query = from k in UserKey, order_by: k.id

        query =
          case filters[:user_id] do
            nil -> query
            user_id -> where(query, [k], k.user_id == ^user_id)
          end

        keys = Repo.all(query)
        Envelope.ok(conn, Enum.map(keys, &key_json/1), meta: Envelope.meta(total: length(keys)))

      {:error, errors} ->
        Envelope.validation_failed(conn, errors)
    end
  end

  def show(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %UserKey{} = key <- Repo.get(UserKey, id) do
      Envelope.ok(conn, key_json(key))
    else
      {:error, errors} -> Envelope.validation_failed(conn, errors)
      nil -> Errors.key_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, attrs} <- Params.validate(params, @create_spec),
         :ok <- ensure_owner_exists(attrs.user_id) do
      case Users.create_key(attrs) do
        {:ok, key} -> Envelope.ok(conn, key_json(key), status: 201)
        {:error, changeset} -> Errors.changeset(conn, changeset, "key")
      end
    else
      {:error, :owner_not_found} -> Errors.user_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def update(conn, %{"id" => raw} = params) do
    with {:ok, id} <- Errors.path_id(raw),
         %UserKey{} = key <- Repo.get(UserKey, id),
         {:ok, attrs} <- Params.validate_partial(params, @update_spec) do
      case Users.update_key(key, attrs) do
        {:ok, updated} -> Envelope.ok(conn, key_json(updated))
        {:error, changeset} -> Errors.changeset(conn, changeset, "key")
      end
    else
      nil -> Errors.key_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def delete(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %UserKey{} = key <- Repo.get(UserKey, id),
         {:ok, _} <- Users.delete_key(key) do
      Envelope.ok(conn, %{deleted_id: key.id})
    else
      nil -> Errors.key_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, _changeset} -> Envelope.fail(conn, 409, "CONFLICT", "key cannot be deleted")
    end
  end

  defp ensure_owner_exists(user_id) do
    if Users.get_user(user_id), do: :ok, else: {:error, :owner_not_found}
  end

  defp key_json(%UserKey{} = key) do
    %{
      id: key.id,
      user_id: key.user_id,
      key_type: key.key_type,
      key_base64: key.key_base64,
      name: key.name,
      extra_comment: key.extra_comment
    }
  end
end
