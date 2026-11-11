defmodule SsmWeb.TimeZone do
  @moduledoc """
  The viewer's time zone (ADR-0014). Storage, the APIs, CSV exports and
  outgoing payloads stay UTC; the web UI shows and accepts the browser's zone.

  `assets/js/app.js` sends the zone as LiveSocket connect param `tz` and as the
  cookie `tz`; `SsmWeb.TimeZonePlug` copies a valid cookie into the session and
  `SsmWeb.TimeZoneHook` assigns `:time_zone` (connect param, else session, else
  `default/0`). Anything that is not a zone name known to the time zone
  database (a string of at most 64 bytes) is ignored without a message.

  Local input is converted with `local_to_utc/2`: a time that does not exist
  (spring forward) moves forward by the gap, an ambiguous one (fall back) is
  the first occurrence.
  """

  @default "Europe/Berlin"
  @max_length 64
  @db Tz.TimeZoneDatabase

  @type zone :: String.t()
  @type fmt :: String.t()

  @doc "Zone used when the browser sent none or an invalid one."
  @spec default() :: zone()
  def default, do: @default

  @doc "The zone name when it is a known zone, else nil."
  @spec valid(term()) :: zone() | nil
  def valid(zone) when is_binary(zone) and byte_size(zone) in 1..@max_length do
    case DateTime.now(zone, @db) do
      {:ok, _now} -> zone
      _ -> nil
    end
  end

  def valid(_zone), do: nil

  @doc "First valid candidate, else the default."
  @spec pick([term()]) :: zone()
  def pick(candidates), do: Enum.find_value(candidates, @default, &valid/1)

  @doc "A UTC `DateTime` in `zone`."
  @spec to_local(DateTime.t(), zone()) :: DateTime.t()
  def to_local(%DateTime{} = utc, zone), do: DateTime.shift_zone!(utc, pick([zone]), @db)

  @doc """
  `DD.MM.YYYY HH:MM` of a UTC `DateTime` in `zone`. `fmt`: `datetime`,
  `datetime-sec` (with seconds), `time-sec`, `date`.
  """
  @spec format(DateTime.t(), zone(), fmt()) :: String.t()
  def format(%DateTime{} = utc, zone, fmt) do
    utc |> to_local(zone) |> Calendar.strftime(pattern(fmt))
  end

  defp pattern("date"), do: "%d.%m.%Y"
  defp pattern("time-sec"), do: "%H:%M:%S"
  defp pattern("datetime-sec"), do: "%d.%m.%Y %H:%M:%S"
  defp pattern(_datetime), do: "%d.%m.%Y %H:%M"

  @doc "A wall-clock time in `zone` as a UTC `DateTime`."
  @spec local_to_utc(NaiveDateTime.t(), zone()) :: DateTime.t()
  def local_to_utc(%NaiveDateTime{} = naive, zone) do
    case DateTime.from_naive(naive, pick([zone]), @db) do
      {:ok, local} -> to_utc(local)
      {:ambiguous, first, _second} -> to_utc(first)
      {:gap, before_gap, _after_gap} -> gap_to_utc(naive, before_gap)
    end
  end

  # The wall time lies in the gap: read it with the offset valid before the
  # gap, which lands it on the same minute after the gap (02:30 -> 03:30).
  defp gap_to_utc(naive, before_gap) do
    offset = before_gap.utc_offset + before_gap.std_offset

    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-offset, :second)
  end

  defp to_utc(%DateTime{} = local), do: DateTime.shift_zone!(local, "Etc/UTC", @db)

  @doc """
  Unix seconds of the first and last second of a calendar day in `zone`
  (the day is as long as the zone makes it: 23 or 25 hours at a DST change).
  """
  @spec day_range(Date.t(), zone()) :: {integer(), integer()}
  def day_range(%Date{} = date, zone) do
    {boundary(date, ~T[00:00:00], zone), boundary(date, ~T[23:59:59], zone)}
  end

  defp boundary(date, time, zone) do
    date |> NaiveDateTime.new!(time) |> local_to_utc(zone) |> DateTime.to_unix()
  end
end
