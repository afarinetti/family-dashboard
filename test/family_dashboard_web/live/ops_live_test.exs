defmodule FamilyDashboardWeb.OpsLiveTest do
  use FamilyDashboardWeb.ConnCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  import Phoenix.LiveViewTest

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  defp authed(conn), do: put_req_header(conn, "authorization", @auth)

  test "requires the settings password", %{conn: conn} do
    conn = get(conn, "/ops")
    assert conn.status == 401
  end

  test "renders the status panel with the seeded setting and no calendars", %{conn: conn} do
    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Ops"
    assert html =~ "last attempted never"
  end

  test "lists a calendar with its sync status", %{conn: conn} do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Family"
    assert html =~ "synced never"
  end

  test "shows a calendar's last_error in red", %{conn: conn} do
    cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    Dashboard.update_calendar!(cal, %{last_error: "boom"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "boom"
  end

  describe "manual triggers" do
    test "refresh_weather enqueues WeatherRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_weather")

      assert_enqueued(worker: WeatherRefresh)
    end

    test "refresh_weather always enqueues, even with a job already pending (force bypass)", %{
      conn: conn
    } do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_weather")
      render_click(live, "refresh_weather")

      assert [_one, _two] = all_enqueued(worker: WeatherRefresh)
    end

    test "refresh_daily enqueues WeatherDailyRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_daily")

      assert_enqueued(worker: WeatherDailyRefresh)
    end

    test "sync_calendar enqueues CalendarSync for the matching id", %{conn: conn} do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      live |> element("button[phx-value-id='#{cal.id}']") |> render_click()

      assert_enqueued(worker: CalendarSync, args: %{calendar_id: cal.id})
    end

    test "sync_calendar ignores an unknown id", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "sync_calendar", %{"id" => Ash.UUID.generate()})

      refute_enqueued(worker: CalendarSync)
    end

    test "sync_all_calendars enqueues only active calendars", %{conn: conn} do
      active = Dashboard.create_calendar!(%{name: "On", ical_url: "https://x/on.ics"})
      Dashboard.create_calendar!(%{name: "Off", ical_url: "https://x/off.ics", active: false})

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "sync_all_calendars")

      assert_enqueued(worker: CalendarSync, args: %{calendar_id: active.id})
      assert [_one] = all_enqueued(worker: CalendarSync)
    end
  end
end
