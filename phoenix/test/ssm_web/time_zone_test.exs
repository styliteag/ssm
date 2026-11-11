defmodule SsmWeb.TimeZoneTest do
  use ExUnit.Case, async: true

  alias SsmWeb.TimeZone

  describe "valid/1 and pick/1" do
    test "accepts known zones, drops everything else" do
      assert TimeZone.valid("Europe/Berlin") == "Europe/Berlin"
      assert TimeZone.valid("America/New_York") == "America/New_York"

      for bad <- [nil, 42, "", "Mars/Olympus", "Europe/Berlin\0", String.duplicate("a", 65), %{}] do
        assert TimeZone.valid(bad) == nil
      end
    end

    test "pick takes the first valid candidate, else Europe/Berlin" do
      assert TimeZone.pick([nil, "nope", "Asia/Tokyo", "Europe/Paris"]) == "Asia/Tokyo"
      assert TimeZone.pick([nil, "nope"]) == "Europe/Berlin"
    end
  end

  describe "local_to_utc/2" do
    test "an ordinary local time" do
      assert utc(~N[2026-01-15 12:00:00]) == ~U[2026-01-15 11:00:00Z]
      assert utc(~N[2026-07-01 12:00:00]) == ~U[2026-07-01 10:00:00Z]
    end

    test "a time that does not exist (spring forward) moves forward by the gap" do
      # 2026-03-29 02:00 CET jumps to 03:00 CEST: 02:30 becomes 03:30 local
      assert utc(~N[2026-03-29 02:30:00]) == ~U[2026-03-29 01:30:00Z]
      assert TimeZone.to_local(utc(~N[2026-03-29 02:30:00]), "Europe/Berlin").hour == 3
    end

    test "an ambiguous time (fall back) is the first occurrence" do
      # 2026-10-25 03:00 CEST falls back to 02:00 CET: 02:30 happens twice
      assert utc(~N[2026-10-25 02:30:00]) == ~U[2026-10-25 00:30:00Z]
    end

    test "an unknown zone falls back to Europe/Berlin" do
      assert TimeZone.local_to_utc(~N[2026-01-15 12:00:00], "nope") == ~U[2026-01-15 11:00:00Z]
    end

    defp utc(naive), do: TimeZone.local_to_utc(naive, "Europe/Berlin")
  end

  describe "day_range/2" do
    test "a local day as unix seconds, across both DST edges" do
      assert range(~D[2026-07-01]) == {~U[2026-06-30 22:00:00Z], ~U[2026-07-01 21:59:59Z]}
      # 23 hours long
      assert range(~D[2026-03-29]) == {~U[2026-03-28 23:00:00Z], ~U[2026-03-29 21:59:59Z]}
      # 25 hours long
      assert range(~D[2026-10-25]) == {~U[2026-10-24 22:00:00Z], ~U[2026-10-25 22:59:59Z]}
    end

    defp range(date) do
      {from, to} = TimeZone.day_range(date, "Europe/Berlin")
      {DateTime.from_unix!(from), DateTime.from_unix!(to)}
    end
  end

  describe "format/3" do
    test "DD.MM.YYYY HH:MM in the zone, seconds where asked" do
      at = ~U[2026-07-01 22:30:05Z]

      assert TimeZone.format(at, "Europe/Berlin", "datetime") == "02.07.2026 00:30"
      assert TimeZone.format(at, "Europe/Berlin", "datetime-sec") == "02.07.2026 00:30:05"
      assert TimeZone.format(at, "Europe/Berlin", "time-sec") == "00:30:05"
      assert TimeZone.format(at, "Europe/Berlin", "date") == "02.07.2026"
      assert TimeZone.format(at, "Asia/Tokyo", "datetime") == "02.07.2026 07:30"
    end
  end
end
