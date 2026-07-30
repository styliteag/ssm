defmodule SsmWeb.Api.HostController do
  @moduledoc """
  `/api/v2/hosts` CRUD — python `api/v2/hosts.py`: same field constraints,
  `jump_via` existence checks (404), self-jump refusal (409), uniqueness
  conflicts (409), and `{"deleted_id": id}` delete payload.
  """

  use SsmWeb, :controller

  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope
  alias SsmWeb.Api.Params

  @create_spec [
    name: [type: :string, required: true, min_len: 1, max_len: 128],
    username: [type: :string, required: true, min_len: 1, max_len: 128],
    address: [type: :string, required: true, min_len: 1, max_len: 253],
    port: [type: :integer, default: 22, min: 1, max: 65_535],
    key_fingerprint: [type: :string, nilable: true, max_len: 1024],
    jump_via: [type: :integer, nilable: true],
    disabled: [type: :boolean, default: false],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  @update_spec [
    name: [type: :string, min_len: 1, max_len: 128],
    username: [type: :string, min_len: 1, max_len: 128],
    address: [type: :string, min_len: 1, max_len: 253],
    port: [type: :integer, min: 1, max: 65_535],
    key_fingerprint: [type: :string, nilable: true, max_len: 1024],
    jump_via: [type: :integer, nilable: true],
    disabled: [type: :boolean],
    comment: [type: :string, nilable: true, max_len: 1024]
  ]

  def index(conn, _params) do
    hosts = Hosts.list_hosts()
    Envelope.ok(conn, Enum.map(hosts, &host_json/1), meta: Envelope.meta(total: length(hosts)))
  end

  def show(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id) do
      Envelope.ok(conn, host_json(host))
    else
      {:error, errors} -> Envelope.validation_failed(conn, errors)
      nil -> Errors.host_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, attrs} <- Params.validate(params, @create_spec),
         :ok <- ensure_jump_exists(attrs) do
      case Hosts.create_host(attrs) do
        {:ok, host} -> Envelope.ok(conn, host_json(host), status: 201)
        {:error, changeset} -> Errors.changeset(conn, changeset, "host")
      end
    else
      {:error, :jump_not_found} -> Errors.host_not_found(conn, "jump_via host not found")
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def update(conn, %{"id" => raw} = params) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, attrs} <- Params.validate_partial(params, @update_spec),
         :ok <- ensure_no_self_jump(attrs, host),
         :ok <- ensure_jump_exists(attrs) do
      case Hosts.update_host(host, attrs) do
        {:ok, updated} -> Envelope.ok(conn, host_json(updated))
        {:error, changeset} -> Errors.changeset(conn, changeset, "host")
      end
    else
      nil -> Errors.host_not_found(conn)
      {:error, :self_jump} -> Envelope.fail(conn, 409, "CONFLICT", "host cannot jump via itself")
      {:error, :jump_not_found} -> Errors.host_not_found(conn, "jump_via host not found")
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def delete(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, _} <- Hosts.delete_host(host) do
      Envelope.ok(conn, %{deleted_id: host.id})
    else
      nil -> Errors.host_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, _changeset} -> Envelope.fail(conn, 409, "CONFLICT", "host cannot be deleted")
    end
  end

  defp ensure_jump_exists(%{jump_via: jump_id}) when is_integer(jump_id) do
    if Hosts.get_host(jump_id), do: :ok, else: {:error, :jump_not_found}
  end

  defp ensure_jump_exists(_attrs), do: :ok

  defp ensure_no_self_jump(%{jump_via: jump_id}, %Host{id: id}) when jump_id == id,
    do: {:error, :self_jump}

  defp ensure_no_self_jump(_attrs, _host), do: :ok

  defp host_json(%Host{} = host) do
    %{
      id: host.id,
      name: host.name,
      username: host.username,
      address: host.address,
      port: host.port,
      key_fingerprint: host.key_fingerprint,
      jump_via: host.jump_via,
      disabled: host.disabled,
      comment: host.comment
    }
  end
end
