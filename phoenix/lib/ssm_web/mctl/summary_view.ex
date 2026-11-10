defmodule SsmWeb.Mctl.SummaryView do
  @moduledoc """
  The mctl contract `HostSummary` of a host (contract-v1 section 9, ssm
  column) from its persisted key check (`Ssm.Diffs.HostCheck`):

    * keys in sync: `ok`
    * drift: `warn`, one item per user and login with the missing and extra
      keys (type, fingerprint, comment; never key material)
    * failed: `crit`, one item named by the failure: `ssh` (unreachable:
      refused, timeout, no route, DNS), `ssh-login` (key refused),
      `ssh-hostkey` (host key changed or not pinned), `sync` (anything else)
    * disabled, or never checked: `unknown`

  `counts` are the logins that are in sync, the drift items and the failure.
  `updated_at` is the later of the host's last edit and the last change of
  its result.
  """

  @max_text 500

  @doc "Summary map of a row from `Ssm.Diffs.HostChecks.page_summaries/3`."
  @spec render(%{
          id: integer(),
          disabled: boolean(),
          updated_at: DateTime.t() | nil,
          check: struct() | nil
        }) :: map()
  def render(%{disabled: true} = row), do: blank(row, "host is disabled")
  def render(%{check: nil} = row), do: blank(row, "never checked")

  def render(%{check: %{state: "synced"} = check} = row) do
    summary(row, check, "ok", "keys in sync", %{ok: check.logins}, [])
  end

  def render(%{check: %{state: "drift"} = check} = row) do
    items = Enum.map(check.drift, &drift_item(&1, check.changed_at))
    drifted_logins = check.drift |> Enum.map(& &1["login"]) |> Enum.uniq() |> length()
    counts = %{ok: max(check.logins - drifted_logins, 0), warn: length(items)}
    summary(row, check, "warn", drift_reason(check.drift), counts, items)
  end

  def render(%{check: %{state: "error"} = check} = row) do
    text = check.error || "the SSH connection failed"
    {name, reason} = failure(check.error_code)
    item = %{name: name, state: "crit", text: text, since: check.changed_at}
    summary(row, check, "crit", reason <> ": " <> text, %{crit: 1}, [item])
  end

  # The item's name tells mctl what failed (`Ssm.Ssh.ErrorCode` codes): only
  # "ssh" means ssm cannot reach the host (mctl shows it as offline); a host
  # that answers but refuses the login or shows another host key is reachable.
  @unreachable ~w(unreachable timeout connect_refused dns_error)
  @host_key ~w(host_key_changed host_key_unpinned)

  defp failure(code) when code in @unreachable, do: {"ssh", "unreachable"}
  defp failure("auth_failed"), do: {"ssh-login", "SSH login refused"}
  defp failure(code) when code in @host_key, do: {"ssh-hostkey", "SSH host key not accepted"}
  defp failure(_code), do: {"sync", "sync failed"}

  defp blank(row, reason) do
    %{
      host_id: to_string(row.id),
      state: "unknown",
      reason: reason,
      counts: counts(%{}),
      items: [],
      checked_at: nil,
      updated_at: row.updated_at
    }
  end

  defp summary(row, check, state, reason, counts, items) do
    %{
      host_id: to_string(row.id),
      state: state,
      reason: reason,
      counts: counts(counts),
      items: items,
      checked_at: check.checked_at,
      updated_at: latest(row.updated_at, check.changed_at)
    }
  end

  defp counts(partial), do: Map.merge(%{ok: 0, warn: 0, crit: 0, unknown: 0}, partial)

  defp latest(nil, b), do: b
  defp latest(a, b), do: Enum.max([a, b], DateTime)

  defp drift_item(entry, since) do
    who = entry["user"] || "unknown key"

    %{
      name: "#{who}@#{entry["login"]}",
      state: "warn",
      text: drift_text(entry),
      since: since
    }
  end

  defp drift_text(entry) do
    [{"missing", entry["missing"]}, {"extra", entry["extra"]}]
    |> Enum.reject(fn {_label, keys} -> keys in [nil, []] end)
    |> Enum.map_join("; ", fn {label, keys} -> "#{label}: #{Enum.join(keys, ", ")}" end)
    |> with_blocked(entry["blocked"])
    |> String.slice(0, @max_text)
  end

  defp with_blocked(text, nil), do: text
  defp with_blocked(text, blocked), do: "#{text}; #{blocked}"

  defp drift_reason(drift) do
    missing = drift |> Enum.map(&length(&1["missing"] || [])) |> Enum.sum()
    extra = drift |> Enum.map(&length(&1["extra"] || [])) |> Enum.sum()

    parts = for {n, label} <- [{missing, "missing"}, {extra, "extra"}], n > 0, do: "#{n} #{label}"
    "key drift: " <> Enum.join(parts, ", ")
  end
end
