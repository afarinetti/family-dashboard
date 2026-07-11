defmodule FamilyDashboard.ICalTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.ICal
  alias FamilyDashboard.ICal.Occurrence

  # Wraps VEVENT bodies in a minimal VCALENDAR envelope.
  defp calendar(vevents) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//FamilyDashboard//Test//EN
    #{vevents}
    END:VCALENDAR
    """
  end

  describe "occurrences_in_window/3 with a single timed event" do
    test "returns the event when it falls inside the window" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:evt-1
        DTSTART:20260708T140000Z
        DTEND:20260708T150000Z
        SUMMARY:Dentist
        LOCATION:Downtown
        END:VEVENT
        """)

      assert [%Occurrence{} = occ] =
               ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert occ.uid == "evt-1"
      assert occ.title == "Dentist"
      assert occ.all_day? == false
      assert DateTime.compare(occ.starts_at, ~U[2026-07-08 14:00:00Z]) == :eq
      assert DateTime.compare(occ.ends_at, ~U[2026-07-08 15:00:00Z]) == :eq
    end

    test "excludes events outside the window" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:evt-far
        DTSTART:20260901T140000Z
        DTEND:20260901T150000Z
        SUMMARY:Way later
        END:VEVENT
        """)

      assert [] = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])
    end
  end

  describe "occurrences_in_window/3 with a recurring event" do
    test "expands a weekly RRULE into each occurrence inside the window" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:20260706T100000Z
        DTEND:20260706T110000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, & &1.title) == [
               "Soccer practice",
               "Soccer practice",
               "Soccer practice"
             ]

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13],
               ~D[2026-07-20]
             ]

      # Duration is preserved on every expanded occurrence.
      assert Enum.all?(occ, &(DateTime.diff(&1.ends_at, &1.starts_at) == 3600))
    end

    test "skips occurrences excluded by EXDATE" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:20260706T100000Z
        DTEND:20260706T110000Z
        RRULE:FREQ=WEEKLY
        EXDATE:20260713T100000Z
        SUMMARY:Soccer practice
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-20]
             ]
    end
  end

  describe "occurrences_in_window/3 with RECURRENCE-ID overrides" do
    test "replaces a single occurrence that was moved to a new time" do
      # The master recurs Mondays at 10:00; the 2026-07-13 instance was moved to 14:00.
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:20260706T100000Z
        DTEND:20260706T110000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        BEGIN:VEVENT
        UID:soccer
        RECURRENCE-ID:20260713T100000Z
        DTSTART:20260713T140000Z
        DTEND:20260713T150000Z
        SUMMARY:Soccer practice (moved)
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, & &1.starts_at) == [
               ~U[2026-07-06 10:00:00Z],
               ~U[2026-07-13 14:00:00Z],
               ~U[2026-07-20 10:00:00Z]
             ]

      assert Enum.at(occ, 1).title == "Soccer practice (moved)"
    end

    test "merges an override when times are zoned (TZID) rather than UTC" do
      # Real Google/Apple feeds express times as TZID=..., not Z. The override
      # must still match the master occurrence it replaces (match by instant).
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART;TZID=Europe/London:20260706T100000
        DTEND;TZID=Europe/London:20260706T110000
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        BEGIN:VEVENT
        UID:soccer
        RECURRENCE-ID;TZID=Europe/London:20260713T100000
        DTSTART;TZID=Europe/London:20260713T140000
        DTEND;TZID=Europe/London:20260713T150000
        SUMMARY:Soccer practice (moved)
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      # If the override fails to match, we'd get 4 (a duplicate on 07-13).
      assert length(occ) == 3

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13],
               ~D[2026-07-20]
             ]

      assert Enum.at(occ, 1).title == "Soccer practice (moved)"
    end

    test "drops a single occurrence cancelled via STATUS:CANCELLED" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:20260706T100000Z
        DTEND:20260706T110000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        BEGIN:VEVENT
        UID:soccer
        RECURRENCE-ID:20260713T100000Z
        DTSTART:20260713T100000Z
        STATUS:CANCELLED
        SUMMARY:Soccer practice
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-20]
             ]
    end
  end

  describe "occurrences_in_window/3 with all-day events" do
    test "flags a VALUE=DATE event as all-day at UTC midnight" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:20260710
        SUMMARY:Trash day
        END:VEVENT
        """)

      assert [%Occurrence{} = occ] =
               ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert occ.title == "Trash day"
      assert occ.all_day? == true
      assert DateTime.compare(occ.starts_at, ~U[2026-07-10 00:00:00Z]) == :eq
    end

    test "expands a recurring all-day event" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:20260706
        RRULE:FREQ=WEEKLY
        SUMMARY:Trash day
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13],
               ~D[2026-07-20]
             ]

      assert Enum.all?(occ, & &1.all_day?)
    end
  end

  describe "occurrences_in_window/3 with RRULE UNTIL" do
    test "caps an all-day recurring series at a date-only UNTIL" do
      # DTSTART;VALUE=DATE + a date-only UNTIL is the RFC 5545 form for an
      # ended all-day series. The underlying `ical` 3.0.0 parser fails to
      # parse this UNTIL shape (requires a "T" + time) and silently drops it
      # to nil, which would otherwise make the series regenerate forever.
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:20260706
        RRULE:FREQ=WEEKLY;UNTIL=20260714
        SUMMARY:Trash day
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13]
             ]
    end

    test "still caps a timed recurring series at a datetime UNTIL" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:20260706T100000Z
        DTEND:20260706T110000Z
        RRULE:FREQ=WEEKLY;UNTIL=20260714T100000Z
        SUMMARY:Soccer practice
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13]
             ]
    end

    test "does not crash on a datetime UNTIL against an all-day series" do
      # A datetime UNTIL parses fine on its own, but paired with an all-day
      # (Date) DTSTART it previously reached for a `:time_zone` field the
      # library's internal Date struct doesn't have and raised a KeyError.
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:20260706
        RRULE:FREQ=WEEKLY;UNTIL=20260714T000000Z
        SUMMARY:Trash day
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13]
             ]
    end

    test "still respects COUNT" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:20260706
        RRULE:FREQ=WEEKLY;COUNT=2
        SUMMARY:Trash day
        END:VEVENT
        """)

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13]
             ]
    end

    test "recovers UNTIL from a folded RRULE line" do
      # RFC 5545 line folding: a CRLF followed by a space/tab is a
      # continuation of the previous line. Real Google/Apple feeds fold long
      # RRULE (and UID) lines this way.
      ics =
        calendar(
          "BEGIN:VEVENT\r\n" <>
            "UID:trash\r\n" <>
            "DTSTART;VALUE=DATE:20260706\r\n" <>
            "RRULE:FREQ=WEEKLY;\r\n UNTIL=20260714\r\n" <>
            "SUMMARY:Trash day\r\n" <>
            "END:VEVENT"
        )

      occ = ICal.occurrences_in_window(ics, ~D[2026-07-06], ~D[2026-07-20])

      assert Enum.map(occ, &DateTime.to_date(&1.starts_at)) == [
               ~D[2026-07-06],
               ~D[2026-07-13]
             ]
    end
  end

  describe "fetch_and_expand/4" do
    test "fetches the feed over HTTP and returns occurrences" do
      ics =
        calendar("""
        BEGIN:VEVENT
        UID:evt-1
        DTSTART:20260708T140000Z
        DTEND:20260708T150000Z
        SUMMARY:Dentist
        END:VEVENT
        """)

      plug = fn conn -> Req.Test.text(conn, ics) end

      assert {:ok, [%Occurrence{title: "Dentist"}]} =
               ICal.fetch_and_expand(
                 "https://example.com/cal.ics",
                 ~D[2026-07-06],
                 ~D[2026-07-20],
                 plug: plug
               )
    end

    test "returns an error tuple on a non-200 response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end

      assert {:error, {:http_status, 404}} =
               ICal.fetch_and_expand(
                 "https://example.com/cal.ics",
                 ~D[2026-07-06],
                 ~D[2026-07-20],
                 plug: plug
               )
    end
  end
end
