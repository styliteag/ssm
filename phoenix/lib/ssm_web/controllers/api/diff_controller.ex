defmodule SsmWeb.Api.DiffController do
  @moduledoc """
  `/api/v2/diffs/{host_id}` + `/sync` — python `api/v2/diffs.py`, backed by
  `Ssm.Diffs` (same engine as the LiveView diff page). Disabled hosts
  short-circuit with 409 HOST_DISABLED before any SSH. A host-wide readonly
  marker aborts the sync before any write (409 SSH_READONLY); a login's own
  `user_readonly` skips only that login, the others are written and the
  response is 409 SSH_READONLY naming skipped and written logins (partial
  sync). Every sync outcome is audit-logged (`Ssm.Diffs.SyncAudit`).

  The sync runs through `Ssm.Diffs.SyncRunner`, like the diff page's: a host
  the runner already syncs (diff page, "Sync all", another API call) is
  refused at once with 409 SYNC_RUNNING and `Retry-After` — nothing is read,
  written or audited for that request. 409 SSH_READONLY stays the partial
  sync. Approved wire change (2026-11-08).

  Each login of a diff carries `notes` (additive): `[{kind, text, line}]`
  from `Ssm.Diffs.Notes`, the notes the diff page shows.
  """

  use SsmWeb, :controller

  alias Ssm.Diffs
  alias Ssm.Diffs.Notes
  alias Ssm.Diffs.SyncRunner
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias SsmWeb.Api.Errors
  alias SsmWeb.Api.Envelope

  # seconds a client should wait before retrying a refused sync
  @sync_retry_after 5

  def show(conn, %{"host_id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         {:ok, diff} <- Diffs.host_diff(id),
         :ok <- ensure_read(diff) do
      Envelope.ok(conn, diff_json(diff))
    else
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, reason} -> diff_error(conn, reason)
    end
  end

  def sync(conn, %{"host_id" => raw}) do
    with {:ok, id} <- Errors.path_id(raw),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, synced} <- audited_sync(conn, host) do
      Envelope.ok(conn, %{
        host_id: host.id,
        host_name: host.name,
        logins: Enum.map(synced, &%{login: &1.login, written_keys: &1.written_keys})
      })
    else
      nil -> Errors.host_not_found(conn)
      {:error, {:sync_running, host}} -> sync_running(conn, host)
      {:error, errors} when is_list(errors) -> Envelope.validation_failed(conn, errors)
      {:error, reason} -> diff_error(conn, reason)
    end
  end

  # a listing that could not be read must never look like an empty host
  defp ensure_read(%{read_error: nil}), do: :ok
  defp ensure_read(%{read_error: message}), do: {:error, {:ssh_connect_failed, message}}

  # sync + audit (actor = token subject) in Ssm.Diffs.SyncRunner; every
  # outcome (success, partial, failure) goes to the audit log there
  defp audited_sync(conn, host) do
    case SyncRunner.run([host], conn.assigns.api_user) do
      {:ok, %{results: [{_host, outcome}]}} -> outcome
      {:ok, %{busy: [_]}} -> {:error, {:sync_running, host}}
      {:error, _} = crashed -> crashed
    end
  end

  defp sync_running(conn, host) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@sync_retry_after))
    |> Envelope.fail(409, "SYNC_RUNNING", "a sync of #{host.name} is already running")
  end

  defp diff_error(conn, :not_found), do: Errors.host_not_found(conn)

  defp diff_error(conn, {:host_disabled, message}),
    do: Envelope.fail(conn, 409, "HOST_DISABLED", message)

  defp diff_error(conn, {:ssh_readonly, message}),
    do: Envelope.fail(conn, 409, "SSH_READONLY", message)

  # stored key rows refused by Ssm.Diffs.KeyLine (control characters,
  # invalid options): the data needs fixing, the other lines were written
  defp diff_error(conn, {:invalid_key_line, message}),
    do: Envelope.fail(conn, 422, "VALIDATION_FAILED", message)

  # SSH_KEY unreadable: writing the login user's file would lock ssm out
  defp diff_error(conn, {:own_key_unavailable, message}),
    do: Envelope.fail(conn, 500, "INTERNAL_ERROR", message)

  defp diff_error(conn, {:ssh_connect_failed, message}),
    do: Envelope.fail(conn, 502, "SSH_CONNECT_FAILED", message)

  defp diff_error(conn, {:crashed, reason}) do
    message = if is_binary(reason), do: reason, else: inspect(reason)
    Envelope.fail(conn, 500, "INTERNAL_ERROR", "sync crashed: #{message}")
  end

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
            # additive: the notes the diff page shows (Ssm.Diffs.Notes)
            notes: Notes.of(login),
            items:
              Enum.map(login.items, fn item ->
                %{status: Atom.to_string(item.status), line: item.line}
              end)
          }
        end)
    }
  end
end
