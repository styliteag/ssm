defmodule SsmWeb.Api.AuthorizationController do
  @moduledoc """
  `/api/v2/authorizations` CRUD — python `api/v2/authorizations.py`:
  `?host_id=`/`?user_id=` list filters, host/user existence checks on create
  (404), uniqueness conflicts (409).
  """

  use SsmWeb, :controller

  import Ecto.Query

  alias Ssm.Authorizations
  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts
  alias Ssm.Repo
  alias Ssm.Users
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @create_spec [
    host_id: [type: :integer, required: true],
    user_id: [type: :integer, required: true],
    login: [type: :string, required: true, min_len: 1, max_len: 128],
    options: [type: :string, nilable: true, max_len: 1024],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @update_spec [
    login: [type: :string, min_len: 1, max_len: 128],
    options: [type: :string, nilable: true, max_len: 1024],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @list_spec [
    host_id: [type: :integer],
    user_id: [type: :integer]
  ]

  def index(conn, params) do
    case Params.validate_partial(params, @list_spec) do
      {:ok, filters} ->
        query = from a in Authorization, order_by: a.id

        query =
          Enum.reduce(filters, query, fn
            {:host_id, host_id}, q -> where(q, [a], a.host_id == ^host_id)
            {:user_id, user_id}, q -> where(q, [a], a.user_id == ^user_id)
          end)

        auths = Repo.all(query)

        Envelope.ok(conn, Enum.map(auths, &auth_json/1),
          meta: Envelope.meta(total: length(auths))
        )

      {:error, errors} ->
        Envelope.validation_failed(conn, errors)
    end
  end

  def show(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Authorization{} = auth <- Authorizations.get_authorization(id) do
      Envelope.ok(conn, auth_json(auth))
    else
      {:error, errors} -> Envelope.validation_failed(conn, errors)
      nil -> Errors.authorization_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, attrs} <- Params.validate(params, @create_spec),
         :ok <- ensure_host_exists(attrs.host_id),
         :ok <- ensure_user_exists(attrs.user_id) do
      case Authorizations.create_authorization(attrs) do
        {:ok, auth} -> Envelope.ok(conn, auth_json(auth), status: 201)
        {:error, changeset} -> Errors.changeset(conn, changeset, "authorization")
      end
    else
      {:error, :host_not_found} -> Errors.host_not_found(conn)
      {:error, :user_not_found} -> Errors.user_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def update(conn, %{"id" => raw} = params) do
    with {:ok, id} <- Errors.path_id(raw),
         %Authorization{} = auth <- Authorizations.get_authorization(id),
         {:ok, attrs} <- Params.validate_partial(params, @update_spec) do
      case Authorizations.update_authorization(auth, attrs) do
        {:ok, updated} -> Envelope.ok(conn, auth_json(updated))
        {:error, changeset} -> Errors.changeset(conn, changeset, "authorization")
      end
    else
      nil -> Errors.authorization_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def delete(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Authorization{} = auth <- Authorizations.get_authorization(id),
         {:ok, _} <- Authorizations.delete_authorization(auth) do
      Envelope.ok(conn, %{deleted_id: auth.id})
    else
      nil -> Errors.authorization_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, _} -> Envelope.fail(conn, 409, "CONFLICT", "authorization cannot be deleted")
    end
  end

  defp ensure_host_exists(host_id),
    do: if(Hosts.get_host(host_id), do: :ok, else: {:error, :host_not_found})

  defp ensure_user_exists(user_id),
    do: if(Users.get_user(user_id), do: :ok, else: {:error, :user_not_found})

  defp auth_json(%Authorization{} = auth) do
    %{
      id: auth.id,
      host_id: auth.host_id,
      user_id: auth.user_id,
      login: auth.login,
      options: auth.options,
      comment: auth.comment
    }
  end
end
