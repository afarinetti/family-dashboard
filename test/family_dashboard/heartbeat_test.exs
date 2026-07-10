defmodule FamilyDashboard.HeartbeatTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.{Dashboard, Heartbeat}
  alias FamilyDashboard.Workers.{CalendarSync, WeatherRefresh}

  # Settings is a singleton; the test DB is seeded with one row (via ash.setup),
  # so configure that row rather than creating a duplicate.
  defp create_setting(attrs \\ %{}) do
    merged =
      Map.merge(
        %{
          latitude: 41.88,
          longitude: -87.63,
          units: "imperial",
          calendar_sync_minutes: 15,
          weather_refresh_minutes: 30,
          sync_max_attempts: 5
        },
        attrs
      )

    case Dashboard.current_setting() do
      {:ok, nil} -> Dashboard.create_setting!(merged)
      {:ok, setting} -> Dashboard.update_setting!(setting, merged)
    end
  end

  describe "run/0 — calendars" do
    test "enqueues a sync for a never-synced active calendar, with the configured retries" do
      create_setting()
      cal = Dashboard.create_calendar!(%{name: "Fam", ical_url: "https://x/cal.ics"})

      assert :ok = Heartbeat.run()

      assert_enqueued(worker: CalendarSync, args: %{calendar_id: cal.id})
      assert [job] = all_enqueued(worker: CalendarSync)
      assert job.max_attempts == 5
    end

    test "does not enqueue a calendar synced within the interval" do
      create_setting(%{calendar_sync_minutes: 15})
      recent = DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)

      cal = Dashboard.create_calendar!(%{name: "Fam", ical_url: "https://x/cal.ics"})
      Dashboard.update_calendar!(cal, %{last_synced_at: recent})

      assert :ok = Heartbeat.run()

      refute_enqueued(worker: CalendarSync)
    end

    test "does not enqueue inactive calendars" do
      create_setting()
      Dashboard.create_calendar!(%{name: "Off", ical_url: "https://x/cal.ics", active: false})

      assert :ok = Heartbeat.run()

      refute_enqueued(worker: CalendarSync)
    end
  end

  describe "run/0 — weather" do
    test "enqueues a weather refresh when there is no reading yet" do
      create_setting()

      assert :ok = Heartbeat.run()

      assert_enqueued(worker: WeatherRefresh)
    end
  end
end
