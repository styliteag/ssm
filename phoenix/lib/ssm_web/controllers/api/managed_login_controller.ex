defmodule SsmWeb.Api.ManagedLoginController do
  @moduledoc """
  `/api/v2/hosts/{id}/managed-logins` (additive): the logins ssm manages on
  a host (`managed_logins`, every login that ever held a grant there) with
  their number of authorizations, and `DELETE …/{login}` to forget one that
  has no authorization and no `authorized_keys` on the host
  (`Ssm.Hosts.ManagedLogins.forget/4`, audited). Errors: 404
  `HOST_NOT_FOUND` / `MANAGED_LOGIN_NOT_FOUND`, 409 `CONFLICT` (grants or a
  file left), 409 `HOST_DISABLED`, 502 `SSH_CONNECT_FAILED`.
  """

  use SsmWeb, :controller

  alias Ssm.Hosts
  alias Ssm.Hosts.{Host, ManagedLogins}
  alias SsmWeb.Api.{Envelope, Errors}

  def index(conn, %{"id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id) do
      logins = ManagedLogins.list(host.id)
      Envelope.ok(conn, logins, meta: Envelope.meta(total: length(logins)))
    else
      nil -> Errors.host_not_found(conn)
      {:error, errors} -> Envelope.validation_failed(conn, errors)
    end
  end

  def delete(conn, %{"id" => raw, "login" => login}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, _} <- ManagedLogins.forget(host, login, conn.assigns.api_user) do
      Envelope.ok(conn, %{host_id: host.id, login: login, forgotten: true})
    else
      nil -> Errors.host_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, reason} -> forget_error(conn, reason)
    end
  end

  defp forget_error(conn, :managed_login_not_found),
    do: Envelope.fail(conn, 404, "MANAGED_LOGIN_NOT_FOUND", "managed login not found")

  defp forget_error(conn, {:conflict, message}), do: Envelope.fail(conn, 409, "CONFLICT", message)

  defp forget_error(conn, {:host_disabled, message}),
    do: Envelope.fail(conn, 409, "HOST_DISABLED", message)

  defp forget_error(conn, {:ssh_connect_failed, message}),
    do: Envelope.fail(conn, 502, "SSH_CONNECT_FAILED", message)

  defp forget_error(conn, reason),
    do: Envelope.fail(conn, 500, "INTERNAL_ERROR", "forget failed: #{inspect(reason)}")
end
