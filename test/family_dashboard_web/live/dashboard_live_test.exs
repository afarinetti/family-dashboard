defmodule FamilyDashboardWeb.DashboardLiveTest do
  use FamilyDashboardWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FamilyDashboard.{Dashboard, Sync}

  defp ymd(date), do: Date.to_iso8601(date, :basic)

  test "renders the greeting and empty states", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Welcome home"
    assert html =~ "Nothing scheduled"
    assert html =~ "No weather data yet."
  end

  test "shows synced calendar events in the agenda", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)

    ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    BEGIN:VEVENT
    UID:e1
    DTSTART:#{ymd(day)}T150000Z
    DTEND:#{ymd(day)}T160000Z
    SUMMARY:Piano lesson
    END:VEVENT
    END:VCALENDAR
    """

    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    :ok = Sync.sync_calendar(calendar, plug: fn conn -> Req.Test.text(conn, ics) end)

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Piano lesson"
  end

  test "colors an event's border using its calendar's Tailwind color", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)

    calendar =
      Dashboard.create_calendar!(%{
        name: "Family",
        ical_url: "https://x/cal.ics",
        color: "orange-600"
      })

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "border-left-color: oklch(64.6% 0.222 41.116)"
  end

  test "falls back to a neutral border when the calendar has no color", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "border-left-color"
    assert html =~ "border-base-300"
  end

  test "falls back to a neutral border when the calendar color isn't a valid Tailwind shade", %{
    conn: conn
  } do
    day = Date.add(Date.utc_today(), 1)

    calendar =
      Dashboard.create_calendar!(%{
        name: "Family",
        ical_url: "https://x/cal.ics",
        color: "javascript:alert(1)"
      })

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "border-left-color"
  end

  test "falls back to a neutral border for a near-miss shade that isn't in the palette", %{
    conn: conn
  } do
    day = Date.add(Date.utc_today(), 1)

    calendar =
      Dashboard.create_calendar!(%{
        name: "Family",
        ical_url: "https://x/cal.ics",
        color: "orange-601"
      })

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "border-left-color"
  end

  test "live-updates the agenda when an events broadcast arrives", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/")
    refute render(live) =~ "Piano lesson"

    day = Date.add(Date.utc_today(), 1)

    ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    BEGIN:VEVENT
    UID:e1
    DTSTART:#{ymd(day)}T150000Z
    DTEND:#{ymd(day)}T160000Z
    SUMMARY:Piano lesson
    END:VEVENT
    END:VCALENDAR
    """

    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    :ok = Sync.sync_calendar(calendar, plug: fn conn -> Req.Test.text(conn, ics) end)

    # The sync broadcast on "events" should have refreshed the mounted LiveView.
    assert render(live) =~ "Piano lesson"
  end

  test "surfaces the weather error when a fetch has failed and there's no reading", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()

    Dashboard.record_weather_status!(setting, %{
      weather_last_error: "Invalid or inactive API key",
      weather_last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Weather unavailable"
    assert html =~ "Invalid or inactive API key"
  end

  test "shows all-day events with an 'All day' label in a negative-offset zone", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{time_zone: "America/Chicago"})

    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    date = Date.add(Date.utc_today(), 2)

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "bday",
      title: "Birthday party",
      all_day: true,
      starts_at: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Birthday party"
    # Must render "All day", not a phantom 7:00 PM from shifting UTC midnight.
    assert html =~ "All day"
  end
end
