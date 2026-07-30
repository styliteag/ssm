defmodule SsmWeb.Api.DiffController do
  @moduledoc """
  `/api/v2/diffs/{host_id}` + `/sync` — python `api/v2/diffs.py`, backed by
  `Ssm.Diffs` (same engine as the LiveView diff page). Disabled hosts
  short-circuit with 409 HOST_DISABLED before any SSH; a readonly sentinel
  aborts sync with 409 SSH_READONLY and never partial-writes.
  """

  use SsmWeb, :controller

  alias Ssm.Diffs
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope

  def show(conn, %{"host_id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         {:ok, diff} <- Diffs.host_diff(id) do
      Envelope.ok(conn, diff_json(diff))
    else
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, reason} -> diff_error(conn, reason)
    end
  end

  def sync(conn, %{"host_id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, synced} <- Diffs.sync_host(id) do
      Envelope.ok(conn, %{
        host_id: host.id,
        host_name: host.name,
        logins: Enum.map(synced, &%{login: &1.login, written_keys: &1.written_keys})
      })
    else
      nil -> Errors.host_not_found(conn)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, reason} -> diff_error(conn, reason)
    end
  end

  defp diff_error(conn, :not_found), do: Errors.host_not_found(conn)

  defp diff_error(conn, {:host_disabled, message}),
    do: Envelope.fail(conn, 409, "HOST_DISABLED", message)

  defp diff_error(conn, {:ssh_readonly, message}),
    do: Envelope.fail(conn, 409, "SSH_READONLY", message)

  defp diff_error(conn, {:ssh_connect_failed, message}),
    do: Envelope.fail(conn, 502, "SSH_CONNECT_FAILED", message)

  defp diff_error(conn, reason),
    do: Envelope.fail(conn, 500, "INTERNAL_ERROR", "diff failed: #{inspect(reason)}")

  defp diff_json(diff) do
    %{
      host_id: diff.host_id,
      host_name: diff.host_name,
      disabled: diff.disabled,
      logins:
        Enum.map(diff.logins, fn login ->
          %{
            login: login.login,
            has_pragma: login.has_pragma,
            readonly_condition: login.readonly_condition,
            read_error: login.read_error,
            items:
              Enum.map(login.items, fn item ->
                %{status: Atom.to_string(item.status), line: item.line}
              end)
          }
        end)
    }
  end
end
