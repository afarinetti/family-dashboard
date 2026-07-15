defmodule FamilyDashboardWeb.DashboardLiveTest do
  use FamilyDashboardWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FamilyDashboard.{Dashboard, Sync}

  defp ymd(date), do: Date.to_iso8601(date, :basic)

  # The dashboard renders times in the configured Setting.time_zone (defaults
  # to "America/Chicago" at the schema level), not UTC — mirror that here
  # instead of assuming UTC, so these tests don't depend on which default is
  # currently seeded.
  defp local_tz do
    case Dashboard.current_setting() do
      {:ok, %{time_zone: tz}} when is_binary(tz) -> tz
      _ -> "Etc/UTC"
    end
  end

  defp local_time(dt),
    do: dt |> DateTime.shift_zone!(local_tz()) |> Calendar.strftime("%-I:%M %p")

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

  test "colors an event's timeline indicator using its calendar's Tailwind color", %{conn: conn} do
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

    assert html =~ "background-color: oklch(64.6% 0.222 41.116)"
  end

  test "falls back to a neutral indicator when the calendar has no color", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "background-color:"
    assert html =~ "bg-base-300"
  end

  test "falls back to a neutral indicator when the calendar color isn't a valid Tailwind shade",
       %{
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

    refute html =~ "background-color:"
  end

  test "falls back to a neutral indicator for a near-miss shade that isn't in the palette", %{
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

    refute html =~ "background-color:"
  end

  test "renders an event's end time and location on their own line", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    starts_at = DateTime.new!(day, ~T[15:30:00], "Etc/UTC")
    ends_at = DateTime.new!(day, ~T[16:30:00], "Etc/UTC")
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Soccer practice",
      location: "Fairview Park",
      starts_at: starts_at,
      ends_at: ends_at
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ local_time(starts_at)
    assert html =~ local_time(ends_at)
    assert html =~ "Fairview Park"
  end

  test "colors the timeline connector (not the row border) for a timed event with a known end",
       %{conn: conn} do
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
      title: "Soccer practice",
      starts_at: DateTime.new!(day, ~T[15:30:00], "Etc/UTC"),
      ends_at: DateTime.new!(day, ~T[16:30:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "background-color: oklch(64.6% 0.222 41.116)"
  end

  test "dims an event on today's agenda that has already ended", %{conn: conn} do
    now = DateTime.utc_now()
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Dentist",
      starts_at: DateTime.add(now, -3600, :second),
      ends_at: DateTime.add(now, -1800, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Dentist"
    assert html =~ "opacity-50"
  end

  test "highlights an event currently in progress", %{conn: conn} do
    now = DateTime.utc_now()
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Book club",
      starts_at: DateTime.add(now, -1800, :second),
      ends_at: DateTime.add(now, 1800, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Book club"
    assert html =~ "bg-base-200/60"
  end

  test "shows the end day for a timed event spanning multiple days", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    ends_at = DateTime.new!(Date.add(day, 2), ~T[12:00:00], "Etc/UTC")
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Camp week",
      starts_at: DateTime.new!(day, ~T[14:00:00], "Etc/UTC"),
      ends_at: ends_at
    })

    {:ok, _live, html} = live(conn, ~p"/")

    local_end_day = ends_at |> DateTime.shift_zone!(local_tz()) |> DateTime.to_date()
    assert html =~ "until #{Calendar.strftime(local_end_day, "%a")}"
    assert html =~ "(Day 1 of 3)"
  end

  test "shows an all-day event as 'All day' with no end line or dimming", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "School holiday",
      all_day: true,
      starts_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
      ends_at: DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "All day"
    refute html =~ "opacity-50"
    refute html =~ "(Day"
  end

  test "shows a (Day X of Y) suffix on the title for a multi-day all-day event", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Camp week",
      all_day: true,
      starts_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
      ends_at: DateTime.new!(Date.add(day, 4), ~T[00:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "All day"
    assert html =~ "(Day 1 of 4)"
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

  test "shows no news ticker when there are no news items", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "animate-marquee"
  end

  test "renders a news item's source badge and headline in the ticker", %{conn: conn} do
    feed =
      Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "item-1",
      title: "Council approves new park",
      url: "https://example.com/park",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Example Feed"
    assert html =~ "Council approves new park"
    assert html =~ "animate-marquee"
  end

  test "orders ticker items newest first across feeds", %{conn: conn} do
    feed =
      Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "older",
      title: "Older headline",
      url: "https://example.com/older",
      published_at: DateTime.add(now, -3600, :second)
    })

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "newer",
      title: "Newer headline",
      url: "https://example.com/newer",
      published_at: now
    })

    {:ok, _live, html} = live(conn, ~p"/")

    # The ticker track is rendered twice back-to-back (for the seamless CSS
    # marquee loop via translateX(-50%)), so both titles always appear twice
    # regardless of order — compare first-occurrence indices, not a regex.
    {newer_index, _} = :binary.match(html, "Newer headline")
    {older_index, _} = :binary.match(html, "Older headline")
    assert newer_index < older_index
  end

  test "shows the alerts card for an active alert that meets the default severity threshold", %{
    conn: conn
  } do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      name: "Severe Thunderstorm Warning",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Weather Alerts"
    assert html =~ "Severe Thunderstorm Warning"
  end

  test "hides the alerts card when the alert is below the configured severity threshold", %{
    conn: conn
  } do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{alerts_min_severity: "severe"})

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "moderate",
      name: "Frost Advisory",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Frost Advisory"
  end

  test "picks up a live setting change on the next clock tick, without remounting", %{
    conn: conn
  } do
    {:ok, setting} = Dashboard.current_setting()

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "moderate",
      name: "Frost Advisory",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, live, html} = live(conn, ~p"/")
    assert html =~ "Frost Advisory"

    # Raise the bar above the existing alert's severity while the LiveView is
    # already mounted. The only way this can take effect is if :tick re-reads
    # the setting instead of relying on the value captured at mount.
    Dashboard.update_setting!(setting, %{alerts_min_severity: "severe"})

    send(live.pid, :tick)

    refute render(live) =~ "Frost Advisory"
  end

  test "hides the alerts card once the alert has expired", %{conn: conn} do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      name: "Severe Thunderstorm Warning",
      begins_at: DateTime.add(now, -7200, :second),
      expires_at: DateTime.add(now, -3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Severe Thunderstorm Warning"
  end

  test "hides a hidden-category alert even when its severity meets the threshold", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{alerts_hidden_categories: "small craft advisory"})

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      category: "small craft advisory",
      name: "Small Craft Advisory",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Small Craft Advisory"
  end

  test "hides hidden-category alerts with whitespace-trimmed entries", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()

    Dashboard.update_setting!(setting, %{
      alerts_hidden_categories: "small craft advisory, tornado warning"
    })

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      category: "tornado warning",
      name: "Tornado Warning",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Tornado Warning"
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

  test "labels today's forecast as 'Today' in a negative-offset zone", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{time_zone: "America/Chicago"})

    # OWM's daily `dt` is always midnight UTC of the calendar day (verified against
    # the live API), not an instant in the location's local time. Shifting it into a
    # negative-UTC-offset zone before taking its date rolls it back to yesterday.
    #
    # Anchored to Chicago's *local* today (not Date.utc_today()) so this isn't flaky
    # for ~5 hours a day (19:00-24:00 Chicago), when the UTC date is already a day
    # ahead of the Chicago date.
    chicago_today = DateTime.now!("America/Chicago") |> DateTime.to_date()
    today_utc_midnight = DateTime.new!(chicago_today, ~T[00:00:00], "Etc/UTC")

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    Dashboard.create_weather_daily!(%{
      weather_reading_id: reading.id,
      forecast_date: today_utc_midnight,
      high: 80.0,
      low: 60.0
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ ~s(class="text-lg font-semibold">Today<)
  end
end
