defmodule Ssm.Diffs.SyncAudit do
  @moduledoc """
  The activity-log entry of a sync (UI and `/api/v2`), from
  `Ssm.Diffs.sync_host_reported/2`: actor, host, the logins written and the
  logins skipped with their reason, and the logins whose `user_readonly`
  was ignored because root does not own it. Action `sync` (success), `sync_partial`
  (failed after some logins were written) or `sync_failed` (nothing
  written); the removal-only sync of `Ssm.Diffs.RevocationSync` logs
  `sync_revocation`, `sync_revocation_partial` and `sync_revocation_failed`.
  Marker text from a host is quoted and bounded.
  """

  alias Ssm.Activity

  @max_text 500

  @doc """
  Log the outcome for `host` (name and id) and return the sync result
  unchanged. `extra` is merged into the details (the removal-only sync adds
  `mode: "removal_only"`); `base` names the action (`"sync"`, or
  `"sync_revocation"` for the removal-only sync).
  """
  @spec log(String.t(), Ssm.Hosts.Host.t(), {term(), map()}, map(), String.t()) :: term()
  def log(actor, %Ssm.Hosts.Host{} = host, {result, report}, extra \\ %{}, base \\ "sync") do
    Activity.log(%{
      activity_type: "host",
      action: action(base, result, report),
      target: host.name,
      host_id: host.id,
      actor_username: actor,
      details: Map.merge(details(result, report), extra)
    })

    result
  end

  defp action(base, {:ok, _}, _report), do: base
  defp action(base, {:error, _}, %{written: []}), do: base <> "_failed"
  defp action(base, {:error, _}, _report), do: base <> "_partial"

  defp details(result, %{written: written, skipped: skipped} = report) do
    base = %{
      ignored: report |> Map.get(:ignored, []) |> Enum.map_join("; ", &ignored_text/1),
      logins: length(written),
      keys: written |> Enum.map(& &1.written_keys) |> Enum.sum(),
      written: Enum.map_join(written, ", ", & &1.login),
      skipped: Enum.map_join(skipped, "; ", &skipped_text/1)
    }

    case result do
      {:ok, _} -> base
      {:error, reason} -> Map.put(base, :error, reason |> error_text() |> bounded())
    end
  end

  defp skipped_text({login, reason}),
    do: "#{inspect(login)} (#{reason |> to_string() |> String.slice(0, 200) |> inspect()})"

  defp ignored_text({login, reason}), do: "#{inspect(login)} (#{reason})"

  defp error_text({_code, message}) when is_binary(message), do: message
  defp error_text(:not_found), do: "host not found"
  defp error_text(other), do: inspect(other)

  defp bounded(text), do: String.slice(text, 0, @max_text)
end
