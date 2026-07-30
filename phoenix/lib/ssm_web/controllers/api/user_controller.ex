defmodule SsmWeb.Api.UserController do
  @moduledoc "`/api/v2/users` CRUD — python `api/v2/users.py`."

  use SsmWeb, :controller

  import Ecto.Query

  alias Ssm.Repo
  alias Ssm.Users
  alias Ssm.Users.User
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @create_spec [
    username: [type: :string, required: true, min_len: 1, max_len: 128],
    enabled: [type: :boolean, default: true],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @update_spec [
    username: [type: :string, min_len: 1, max_len: 128],
    enabled: [type: :boolean],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  def index(conn, _params) do
    users = Repo.all(from u in User, order_by: u.id)
    Envelope.ok(conn, Enum.map(users, &user_json/1), meta: Envelope.meta(total: length(users)))
  end

  def show(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %User{} = user <- Users.get_user(id) do
      Envelope.ok(conn, user_json(user))
    else
      {:error, errors} -> Envelope.validation_failed(conn, errors)
      nil -> Errors.user_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, attrs} <- Params.validate(params, @create_spec) do
      case Users.create_user(attrs) do
        {:ok, user} -> Envelope.ok(conn, user_json(user), status: 201)
        {:error, changeset} -> Errors.changeset(conn, changeset, "user")
      end
    else
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def update(conn, %{"id" => raw} = params) do
    with {:ok, id} <- Errors.path_id(raw),
         %User{} = user <- Users.get_user(id),
         {:ok, attrs} <- Params.validate_partial(params, @update_spec) do
      case Users.update_user(user, attrs) do
        {:ok, updated} -> Envelope.ok(conn, user_json(updated))
        {:error, changeset} -> Errors.changeset(conn, changeset, "user")
      end
    else
      nil -> Errors.user_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def delete(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %User{} = user <- Users.get_user(id),
         {:ok, _} <- Users.delete_user(user) do
      Envelope.ok(conn, %{deleted_id: user.id})
    else
      nil -> Errors.user_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, _changeset} -> Envelope.fail(conn, 409, "CONFLICT", "user cannot be deleted")
    end
  end

  defp user_json(%User{} = user) do
    %{id: user.id, username: user.username, enabled: user.enabled, comment: user.comment}
  end
end
