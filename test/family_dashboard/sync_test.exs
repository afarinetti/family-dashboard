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
  defp two_event_feed do
    d1 = Date.add(Date.utc_today(), 2)
    d2 = Date.add(Date.utc_today(), 5)

    calendar_feed("""
    BEGIN:VEVENT
    UID:e1
    DTSTART:#{ymd(d1)}T100000Z
    DTEND:#{ymd(d1)}T110000Z
    SUMMARY:Alpha
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
  end

  describe "refresh_weather/1" do
    defp weather_plug do
      current = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => 70.0,
            "feels_like" => 68.0,
            "weather" => [%{"description" => "clear sky", "icon" => "01d"}]
          }
        ]
      }

      hourly = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => 70.0,
            "pop" => 0.0,
            "weather" => [%{"icon" => "01d"}]
          }
        ]
      }

      daily = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => %{"min" => 60.0, "max" => 80.0},
            "weather" => [%{"icon" => "01d"}]
          }
        ]
      }

      fn conn ->
        case conn.request_path do
          "/data/4.0/onecall/current" -> Req.Test.json(conn, current)
          "/data/4.0/onecall/timeline/1h" -> Req.Test.json(conn, hourly)
          "/data/4.0/onecall/timeline/1day" -> Req.Test.json(conn, daily)
        end
      end
    end

    test "records a reading and broadcasts when a location is configured" do
      # The test DB is seeded with a Chicago location via ash.setup.
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")

      assert :ok = Sync.refresh_weather(plug: weather_plug())

      assert_receive :weather_updated
      reading = Dashboard.latest_weather!()
      assert reading.temp == 70.0
      assert reading.condition == "clear sky"
    end

    test "carries forward the last 7-day forecast when a refresh returns empty days" do
      # First refresh populates the daily forecast.
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert length(Dashboard.latest_weather!().forecast["days"]) == 1

      # Next refresh: daily comes back empty (OWM intermittently does this).
      empty_daily = fn conn ->
        body =
          case conn.request_path do
            "/data/4.0/onecall/current" ->
              %{
                "data" => [
                  %{"dt" => 1_783_000_000, "temp" => 72.0, "weather" => [%{"icon" => "01d"}]}
                ]
              }

            _ ->
              %{"data" => []}
          end

        Req.Test.json(conn, body)
      end

      assert :ok = Sync.refresh_weather(plug: empty_daily)
      # The new reading kept the previously-known 7-day forecast.
      assert length(Dashboard.latest_weather!().forecast["days"]) == 1
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
