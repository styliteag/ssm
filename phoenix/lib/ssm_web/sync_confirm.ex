defmodule SsmWeb.SyncConfirm do
  @moduledoc """
  Confirm texts for the buttons that write to hosts (diff page "Sync",
  per-row sync, "Sync all"). A sync replaces each managed authorized_keys
  file, so every line ssm does not grant is removed — keys added by
  hand on the host included. The texts say so, together with the numbers
  of the last check (`Ssm.HostStatus` values), so nobody locks themselves
  out by a misclick. Pure: no database, no SSH.
  """

  alias Ssm.Hosts.Host

  @removal "Every key line that ssm does not grant is removed, including keys added by hand on the host."

  @doc "Confirm text for syncing one host, from its current status."
  @spec host(Host.t(), term()) :: String.t()
  def host(%Host{name: name}, status), do: "Sync #{name}? " <> host_effect(status)

  defp host_effect({:drift, missing, extra}),
    do: "It #{adds_removes(missing, extra)} (last check). " <> @removal

  defp host_effect(:synced),
    do: "The last check found no differences; ssm rewrites the managed files anyway. " <> @removal

  defp host_effect(status) when status in [:unchecked, :loading],
    do: "This host is not checked yet, so the changes are unknown. " <> @removal

  defp host_effect(_failed),
    do: "The last check of this host failed, so the changes are unknown. " <> @removal

  @doc """
  Confirm text for "Sync all", or nil when no enabled host needs a sync
  (the page then answers "Nothing to sync." without asking).
  """
  @spec all([Host.t()], map(), map()) :: String.t() | nil
  def all(hosts, statuses, checks) do
    enabled = Enum.reject(hosts, & &1.disabled)
    drifting = Enum.filter(enabled, &match?({:drift, _, _}, statuses[&1.id]))

    case drifting do
      [] -> nil
      _ -> all_text(drifting, enabled, statuses, checks)
    end
  end

  defp all_text(drifting, enabled, statuses, checks) do
    {missing, extra} =
      Enum.reduce(drifting, {0, 0}, fn host, {m, e} ->
        {:drift, dm, de} = statuses[host.id]
        {m + dm, e + de}
      end)

    skipped = Enum.count(enabled, &(not synced_or_drifting?(statuses[&1.id])))

    [
      "Sync #{count(length(drifting), "host")} that need it? ",
      "This #{adds_removes(missing, extra)}#{age(drifting, checks)}. ",
      "Every key line that ssm does not grant is removed, including keys added by hand on the hosts.",
      skipped_text(skipped)
    ]
    |> IO.iodata_to_binary()
  end

  defp synced_or_drifting?(:synced), do: true
  defp synced_or_drifting?({:drift, _, _}), do: true
  defp synced_or_drifting?(_), do: false

  defp skipped_text(0), do: ""

  defp skipped_text(n),
    do:
      " #{count(n, "host")} not checked or with a failed check #{if n == 1, do: "is", else: "are"} skipped."

  # " (checked just now)" / " (oldest check 3 h ago)": the numbers are only
  # as fresh as the oldest check behind them.
  defp age(hosts, checks) do
    hosts
    |> Enum.map(&checks[&1.id])
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1.checked_at, DateTime, fn -> nil end)
    |> case do
      nil -> ""
      check -> age_text(ago(check.checked_at))
    end
  end

  defp age_text("just now"), do: " (checked just now)"
  defp age_text(ago), do: " (oldest check #{ago})"

  defp adds_removes(missing, extra),
    do: "adds #{count(missing, "key line")} and removes #{count(extra, "key line")}"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  @doc "\"just now\", \"5 min ago\", \"3 h ago\", \"2 d ago\"."
  @spec ago(DateTime.t()) :: String.t()
  def ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      s when s < 60 -> "just now"
      s when s < 3600 -> "#{div(s, 60)} min ago"
      s when s < 86_400 -> "#{div(s, 3600)} h ago"
      s -> "#{div(s, 86_400)} d ago"
    end
  end
end
