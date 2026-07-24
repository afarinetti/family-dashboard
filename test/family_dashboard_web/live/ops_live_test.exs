defmodule FamilyDashboardWeb.OpsLiveTest do
  use FamilyDashboardWeb.ConnCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  import Phoenix.LiveViewTest

  alias FamilyDashboard.Backup
  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, NewsRefresh, WeatherDailyRefresh, WeatherRefresh}

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

  test "lists a news feed with its fetch status", %{conn: conn} do
    Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Example Feed"
    assert html =~ "fetched never"
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

    test "refresh_news enqueues NewsRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_news")

      assert_enqueued(worker: NewsRefresh)
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

  describe "backup & restore" do
    test "save_backup_to_disk writes a file and flashes success", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "ops_live_backup_test")
      File.rm_rf!(tmp)
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.put_env(:family_dashboard, :backup_dir, original)
      end)

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "save_backup_to_disk")

      assert html =~ "Backup saved"
      assert File.ls!(tmp) != []
    end

    test "request_restore then cancel_restore hides the confirm step", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "request_restore")
      assert html =~ "Yes, overwrite"

      html = render_click(live, "cancel_restore")
      refute html =~ "Yes, overwrite"
    end

    test "confirming restore without a selected file shows an error", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "request_restore")
      html = render_click(live, "confirm_restore")

      assert html =~ "Choose a backup file first."
    end

    test "lists server backups found in the backup dir", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "ops_live_backup_test_list")
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "family_dashboard_backup_test.json"), "{}")
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.put_env(:family_dashboard, :backup_dir, original)
      end)

      {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

      assert html =~ "family_dashboard_backup_test.json"
    end

    test "request_restore_from_server then cancel_restore hides the confirm step", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "ops_live_backup_test_server")
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "backup.json"), "{}")
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.put_env(:family_dashboard, :backup_dir, original)
      end)

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "request_restore_from_server", %{"filename" => "backup.json"})
      assert html =~ "Yes, overwrite"

      html = render_click(live, "cancel_restore")
      refute html =~ "Yes, overwrite"
    end

    test "restoring a server backup upserts calendars and flashes a summary", %{conn: conn} do
      cal = Dashboard.create_calendar!(%{name: "Old", ical_url: "https://x/old.ics"})

      tmp = Path.join(System.tmp_dir!(), "ops_live_backup_test_server_restore")
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Restored",
            "ical_url" => "https://x/old.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      File.write!(Path.join(tmp, "backup.json"), backup)
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.put_env(:family_dashboard, :backup_dir, original)
      end)

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "request_restore_from_server", %{"filename" => "backup.json"})
      html = render_click(live, "confirm_restore_from_server", %{"filename" => "backup.json"})

      assert html =~ "Restored 1 calendar(s)"
      assert Dashboard.get_calendar!(cal.id).name == "Restored"
    end

    test "confirming a server restore without matching the pending filename is rejected", %{
      conn: conn
    } do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "confirm_restore_from_server", %{"filename" => "backup.json"})

      assert html =~ "Restore was not confirmed."
    end

    test "restoring an uploaded backup upserts calendars and flashes a summary", %{conn: conn} do
      cal = Dashboard.create_calendar!(%{name: "Old", ical_url: "https://x/old.ics"})

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Restored",
            "ical_url" => "https://x/old.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      file =
        file_input(live, "#restore-form", :backup, [
          %{name: "backup.json", content: backup, type: "application/json"}
        ])

      render_upload(file, "backup.json")
      render_click(live, "request_restore")
      html = live |> element("#restore-form") |> render_submit()

      assert html =~ "Restored 1 calendar(s)"
      assert Dashboard.get_calendar!(cal.id).name == "Restored"
    end
  end
end
