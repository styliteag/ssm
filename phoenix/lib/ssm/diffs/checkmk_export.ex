defmodule Ssm.Diffs.CheckmkExport do
  @moduledoc """
  The periodic key check as STYLiTE Orbit Monitor reads it
  (`GET /api/export/checkmk`, `SsmWeb.CheckmkExportController`): the
  Orbit Dashboard's export shape, version 1, so that Orbit Monitor's
  special agent turns every host into a piggyback host with one local
  service `ssh_keys`.

      %{"version" => 1, "instances" => [%{"instance_id", "name", "host",
        "device_type" => "ssh_host", "checks" => [%{"key" => "ssh_keys",
        "state", "summary", "metrics" => []}]}]}

  One instance per enabled host, named after the host (`name` and `host`
  are both the ssm host name, never its address). States (0 OK, 1 WARN,
  2 CRIT, 3 UNKNOWN):

    * keys in sync: OK
    * drift (also drift a sync cannot remove): CRIT
    * host key differs from the pinned one: CRIT
    * any other failed check (unreachable, login refused, host key not
      pinned yet): WARN with the stored fixed sentence
    * last check older than `stale_after` seconds: UNKNOWN
    * never checked: the instance has no check yet

  Reads only `host_checks` (`Ssm.Diffs.HostChecks.export_rows/0`): building
  the export never opens an SSH connection. Summaries hold counts and fixed
  sentences only, never key labels or addresses.
  """

  alias Ssm.Diffs.{HostCheck, HostChecks, SyncScheduler}

  @version 1
  @key "ssh_keys"
  @stale_intervals 3

  @doc "The export of all enabled hosts now."
  @spec current(DateTime.t()) :: map()
  def current(now \\ DateTime.utc_now()),
    do: build(HostChecks.export_rows(), now, stale_after())

  @doc """
  Seconds after which a stored check counts as stale: three periodic check
  intervals (`SSM_SYNC_INTERVAL`; the default interval when the check is
  off or the value is invalid, so old results turn UNKNOWN).
  """
  @spec stale_after() :: pos_integer()
  def stale_after do
    raw = Application.get_env(:ssm, :sync_check, []) |> Keyword.get(:interval)
    {:ok, default} = SyncScheduler.parse_interval(nil)

    seconds =
      case SyncScheduler.parse_interval(raw) do
        {:ok, seconds} -> seconds
        _off_or_error -> default
      end

    @stale_intervals * seconds
  end

  @doc "The export document of `rows` (`%{id, name, check}`), pure."
  @spec build([map()], DateTime.t(), pos_integer()) :: map()
  def build(rows, %DateTime{} = now, stale_after) do
    %{"version" => @version, "instances" => Enum.map(rows, &instance(&1, now, stale_after))}
  end

  defp instance(%{id: id, name: name, check: check}, now, stale_after) do
    %{
      "instance_id" => id,
      "name" => name,
      "host" => name,
      "device_type" => "ssh_host",
      "checks" => checks(check, now, stale_after)
    }
  end

  defp checks(nil, _now, _stale_after), do: []

  defp checks(%HostCheck{} = check, now, stale_after) do
    age = DateTime.diff(now, check.checked_at)

    {state, summary} =
      if age > stale_after,
        do: {3, "last key check #{div(age, 60)} min ago"},
        else: result(check)

    [%{"key" => @key, "state" => state, "summary" => summary, "metrics" => []}]
  end

  defp result(%HostCheck{state: "synced", logins: logins}),
    do: {0, "#{plural(logins, "login")} in sync"}

  defp result(%HostCheck{state: "drift", drift: drift}), do: {2, drift_summary(drift)}

  defp result(%HostCheck{state: "error", error_code: "host_key_changed"}),
    do: {2, "host key differs from the pinned one"}

  defp result(%HostCheck{state: "error", error: error}),
    do: {1, error || "the SSH connection failed"}

  defp drift_summary(drift) do
    logins = drift |> Enum.map(& &1["login"]) |> Enum.uniq() |> length()
    missing = count(drift, "missing")
    extra = count(drift, "extra")

    parts =
      for {n, text} <- [{missing, "#{plural(missing, "key")} missing"}, {extra, "#{extra} extra"}],
          n > 0,
          do: text

    "drift on #{plural(logins, "login")}: " <> Enum.join(parts, ", ")
  end

  defp count(drift, field), do: drift |> Enum.map(&length(&1[field] || [])) |> Enum.sum()

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
