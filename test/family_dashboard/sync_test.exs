defmodule FamilyDashboard.SyncTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, Sync}

  defp ymd(date), do: Date.to_iso8601(date, :basic)

  defp calendar_feed(vevents) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//FamilyDashboard//Test//EN
    #{vevents}
    END:VCALENDAR
    """
  end

  # Two events a few days out, safely inside the rolling window.
  defp two_event_feed(alpha_title \\ "Alpha") do
    d1 = Date.add(Date.utc_today(), 2)
    d2 = Date.add(Date.utc_today(), 5)

    calendar_feed("""
    BEGIN:VEVENT
    UID:e1
    DTSTART:#{ymd(d1)}T100000Z
    DTEND:#{ymd(d1)}T110000Z
    SUMMARY:#{alpha_title}
    END:VEVENT
    BEGIN:VEVENT
    UID:e2
    DTSTART:#{ymd(d2)}T120000Z
    DTEND:#{ymd(d2)}T130000Z
    SUMMARY:Beta
    END:VEVENT
    """)
  end

  defp window_events(calendar_id) do
    from = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(Date.utc_today(), 30), ~T[00:00:00], "Etc/UTC")

    Dashboard.events_in_window!(from, to)
    |> Enum.filter(&(&1.calendar_id == calendar_id))
  end

  defp create_calendar do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://example.com/cal.ics"})
  end

  describe "sync_calendar/2" do
    test "fetches the feed and stores its occurrences" do
      cal = create_calendar()
      plug = fn conn -> Req.Test.text(conn, two_event_feed()) end

      assert :ok = Sync.sync_calendar(cal, plug: plug)

      titles = cal.id |> window_events() |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Alpha", "Beta"]

      reloaded = Dashboard.get_calendar!(cal.id)
      assert reloaded.last_synced_at
      assert reloaded.last_attempted_at
      assert is_nil(reloaded.last_error)
    end

    test "records last_error and does not stamp last_synced_at on failure" do
      cal = create_calendar()
      plug = fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end

      assert {:error, _reason} = Sync.sync_calendar(cal, plug: plug)

      reloaded = Dashboard.get_calendar!(cal.id)
      assert reloaded.last_error
      assert reloaded.last_attempted_at
      assert is_nil(reloaded.last_synced_at)
      assert window_events(cal.id) == []
    end

    test "replaces window events so removed events disappear" do
      cal = create_calendar()

      assert :ok =
               Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, two_event_feed()) end)

      assert length(window_events(cal.id)) == 2

      d1 = Date.add(Date.utc_today(), 2)

      one_event =
        calendar_feed("""
        BEGIN:VEVENT
        UID:e1
        DTSTART:#{ymd(d1)}T100000Z
        DTEND:#{ymd(d1)}T110000Z
        SUMMARY:Alpha
        END:VEVENT
        """)

      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, one_event) end)

      assert cal.id |> window_events() |> Enum.map(& &1.title) == ["Alpha"]
    end

    test "broadcasts an events update after committing" do
      cal = create_calendar()
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")

      assert :ok =
               Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, two_event_feed()) end)

      assert_receive :events_updated
    end

    test "upserts on re-sync: a changed title updates the existing row instead of duplicating" do
      cal = create_calendar()

      assert :ok =
               Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, two_event_feed()) end)

      [alpha] = cal.id |> window_events() |> Enum.filter(&(&1.title == "Alpha"))

      renamed_feed = fn conn -> Req.Test.text(conn, two_event_feed("Alpha (renamed)")) end
      assert :ok = Sync.sync_calendar(cal, plug: renamed_feed)

      events = window_events(cal.id)
      assert length(events) == 2
      assert Enum.map(events, & &1.title) |> Enum.sort() == ["Alpha (renamed)", "Beta"]

      # Same row, not a duplicate — the id is stable across the upsert.
      [updated_alpha] = Enum.filter(events, &(&1.title == "Alpha (renamed)"))
      assert updated_alpha.id == alpha.id
    end

    test "a recurring series whose UNTIL ends is pruned down to just the remaining occurrences" do
      cal = create_calendar()
      d0 = ymd(Date.utc_today())

      recurring =
        calendar_feed("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:#{d0}
        RRULE:FREQ=WEEKLY
        SUMMARY:Trash day
        END:VEVENT
        """)

      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, recurring) end)
      assert length(window_events(cal.id)) > 1

      ended =
        calendar_feed("""
        BEGIN:VEVENT
        UID:trash
        DTSTART;VALUE=DATE:#{d0}
        RRULE:FREQ=WEEKLY;UNTIL=#{d0}
        SUMMARY:Trash day
        END:VEVENT
        """)

      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, ended) end)
      assert length(window_events(cal.id)) == 1
    end

    test "a feed that empties out prunes the whole window without raising" do
      cal = create_calendar()

      assert :ok =
               Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, two_event_feed()) end)

      assert length(window_events(cal.id)) == 2

      empty = calendar_feed("")
      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, empty) end)

      assert window_events(cal.id) == []
    end

    test "a RECURRENCE-ID move leaves no ghost at the old start time" do
      cal = create_calendar()
      d0 = Date.utc_today()
      d1 = Date.add(d0, 7)

      original =
        calendar_feed("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:#{ymd(d0)}T100000Z
        DTEND:#{ymd(d0)}T110000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        """)

      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, original) end)
      assert length(window_events(cal.id)) == 4

      moved =
        calendar_feed("""
        BEGIN:VEVENT
        UID:soccer
        DTSTART:#{ymd(d0)}T100000Z
        DTEND:#{ymd(d0)}T110000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Soccer practice
        END:VEVENT
        BEGIN:VEVENT
        UID:soccer
        RECURRENCE-ID:#{ymd(d1)}T100000Z
        DTSTART:#{ymd(d1)}T140000Z
        DTEND:#{ymd(d1)}T150000Z
        SUMMARY:Soccer practice (moved)
        END:VEVENT
        """)

      assert :ok = Sync.sync_calendar(cal, plug: fn conn -> Req.Test.text(conn, moved) end)

      events = window_events(cal.id)
      # Still 4 occurrences total: the old 10:00 slot on d1 is gone, replaced
      # by the moved 14:00 one — not left behind as a stale extra row.
      assert length(events) == 4
      titles_by_start = Map.new(events, &{&1.starts_at, &1.title})
      refute Map.has_key?(titles_by_start, DateTime.new!(d1, ~T[10:00:00], "Etc/UTC"))

      assert titles_by_start[DateTime.new!(d1, ~T[14:00:00], "Etc/UTC")] ==
               "Soccer practice (moved)"
    end
  end

  describe "refresh_weather/1" do
    # Xweather-shaped fixtures (the default provider, pinned in config/test.exs).
    # Matched on path *prefix* + the "filter" query param rather than the exact
    # lat/lon path segment, since the Setting singleton's coordinates aren't
    # under this test's control (see `current_setting/0`).
    defp weather_plug do
      current = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "feelslikeF" => 68.0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      hourly = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "pop" => 0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      daily = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "maxTempF" => 80.0,
                "minTempF" => 60.0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      alerts = %{"success" => true, "response" => []}

      fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, current)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, hourly)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "day" ->
            Req.Test.json(conn, daily)

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, alerts)
        end
      end
    end

    test "records a reading (with hourly rows) and broadcasts when a location is configured" do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")

      assert :ok = Sync.refresh_weather(plug: weather_plug())

      assert_receive :weather_updated
      reading = Dashboard.latest_weather!()
      assert reading.temp == 70.0
      assert reading.condition == "clear sky"
      assert length(reading.hourly) == 1
      assert List.first(reading.hourly).temp == 70.0
    end

    test "the current+hourly refresh does not fetch daily data" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert Dashboard.latest_weather!().daily == []
    end

    test "persists and broadcasts alerts fetched alongside current+hourly" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [
                %{
                  "details" => %{
                    "type" => "AW.TS.SV",
                    "name" => "Severe Thunderstorm Warning",
                    "priority" => 2,
                    "cat" => "thunderstorm"
                  },
                  "timestamps" => %{"begins" => 1_783_000_000, "expires" => 1_783_003_600}
                }
              ]
            })
        end
      end

      assert :ok = Sync.refresh_weather(plug: plug)

      reading = Dashboard.latest_weather!()
      assert length(reading.alerts) == 1
      assert List.first(reading.alerts).name == "Severe Thunderstorm Warning"
      assert List.first(reading.alerts).severity == "severe"
    end

    test "a failing alerts fetch still yields a successful reading, with zero alerts" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert :ok = Sync.refresh_weather(plug: plug)

      reading = Dashboard.latest_weather!()
      assert reading.temp == 70.0
      assert reading.alerts == []
    end

    test "alerts are not carried forward when a later refresh's alert fetch fails" do
      populated_plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [
                %{
                  "details" => %{"type" => "AW.TS.SV", "name" => "Severe Thunderstorm Warning"},
                  "timestamps" => %{}
                }
              ]
            })
        end
      end

      failing_alerts_plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 71.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert :ok = Sync.refresh_weather(plug: populated_plug)
      assert length(Dashboard.latest_weather!().alerts) == 1

      assert :ok = Sync.refresh_weather(plug: failing_alerts_plug)
      # Unlike `daily`, a failed alerts fetch on this NEW reading must not
      # inherit the previous reading's alerts — a stale severe-weather
      # warning is worse than a blank card.
      assert Dashboard.latest_weather!().alerts == []
    end
  end

  describe "refresh_daily/1" do
    test "patches the latest reading's 7-day and today's high/low" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert Dashboard.latest_weather!().daily == []

      assert :ok = Sync.refresh_daily(plug: weather_plug())

      reading = Dashboard.latest_weather!()
      assert length(reading.daily) == 1
      assert reading.high == 80.0
      assert reading.low == 60.0
      # hourly data is untouched by the daily job
      assert reading.hourly != []
    end

    test "a later current+hourly refresh carries the 7-day forward onto the new reading" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert :ok = Sync.refresh_daily(plug: weather_plug())
      assert length(Dashboard.latest_weather!().daily) == 1

      # New current+hourly reading is a NEW row that carries the last known days
      # + high/low forward, so the widget stays populated between daily runs.
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      reading = Dashboard.latest_weather!()
      assert length(reading.daily) == 1
      assert reading.high == 80.0
    end

    test "returns an error when the daily endpoint has no data" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())

      empty = fn conn ->
        Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})
      end

      assert {:error, :no_daily} = Sync.refresh_daily(plug: empty)
    end

    test "borrows today's icon/condition from the hourly forecast when the daily endpoint's icon is missing" do
      # This is a defense-in-depth safety net, not the common case: Xweather's
      # /forecasts (unlike OWM's /timeline/1day) reliably returns real daily
      # icons/conditions. But should a provider ever omit today's, borrow it
      # from the hourly forecast rather than showing a blank icon.
      current = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "weather" => "rain showers",
                "icon" => "shwrs.png"
              }
            ]
          }
        ]
      }

      hourly = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "pop" => 0,
                "weather" => "rain showers",
                "icon" => "shwrs.png"
              }
            ]
          }
        ]
      }

      daily_no_icon = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{"timestamp" => 1_783_000_000, "maxTempF" => 80.0, "minTempF" => 60.0}
            ]
          }
        ]
      }

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, current)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, hourly)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "day" ->
            Req.Test.json(conn, daily_no_icon)

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{"success" => true, "response" => []})
        end
      end

      assert :ok = Sync.refresh_weather(plug: plug)
      assert :ok = Sync.refresh_daily(plug: plug)

      today = Dashboard.latest_weather!().daily |> List.first()
      assert today.icon == "showers"
      assert today.condition == "rain showers"
    end

    test "records a human-readable weather_last_error on a fetch failure" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"message":"Invalid API key"})) end

      assert {:error, {:http_status, 401}} = Sync.refresh_weather(plug: plug)

      {:ok, setting} = Dashboard.current_setting()
      assert setting.weather_last_error =~ "Invalid or inactive API key"
      assert setting.weather_last_attempted_at
    end

    test "clears weather_last_error after a subsequent successful refresh" do
      fail_plug = fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end
      assert {:error, _} = Sync.refresh_weather(plug: fail_plug)
      assert Dashboard.current_setting!().weather_last_error

      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert is_nil(Dashboard.current_setting!().weather_last_error)
    end
  end
end
