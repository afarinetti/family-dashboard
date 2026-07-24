defmodule FamilyDashboard.BackupTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Backup, Dashboard}

  @tmp_dir Path.join(System.tmp_dir!(), "family_dashboard_backup_test")

  setup do
    File.rm_rf!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "export/0 and export_json/0" do
    test "includes version, calendars, news feeds, and the singleton setting" do
      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      Dashboard.create_news_feed!(%{url: "https://x/feed.xml", label: "Local news"})

      data = Backup.export()

      assert data["version"] == 1
      assert data["exported_at"]
      assert [%{"name" => "Family", "ical_url" => "https://x/cal.ics"}] = data["calendars"]

      assert [%{"url" => "https://x/feed.xml", "label" => "Local news"}] = data["news_feeds"]

      assert data["setting"]["time_zone"]
    end

    test "includes every operator-editable setting field, not just a subset" do
      Dashboard.update_setting!(elem(Dashboard.current_setting(), 1), %{
        alerts_min_severity: "severe",
        alerts_hidden_categories: "small craft advisory",
        alerts_always_show_categories: "heat,flood",
        alerts_show_body: true,
        news_refresh_minutes: 30,
        news_retention_hours: 48,
        news_ticker_chars_per_second: 20
      })

      setting = Backup.export()["setting"]

      assert setting["alerts_min_severity"] == "severe"
      assert setting["alerts_hidden_categories"] == "small craft advisory"
      assert setting["alerts_always_show_categories"] == "heat,flood"
      assert setting["alerts_show_body"] == true
      assert setting["news_refresh_minutes"] == 30
      assert setting["news_retention_hours"] == 48
      assert setting["news_ticker_chars_per_second"] == 20
    end

    test "export_json/0 produces valid, round-trippable JSON" do
      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      assert {:ok, decoded} = Backup.export_json() |> Jason.decode()
      assert decoded["version"] == 1
    end
  end

  describe "write_to_disk/2" do
    test "creates the directory and writes a timestamped file" do
      assert {:ok, path} = Backup.write_to_disk(~s({"ok":true}), @tmp_dir)

      assert File.exists?(path)
      assert Path.dirname(path) == @tmp_dir
      assert File.read!(path) == ~s({"ok":true})
    end
  end

  describe "import_json/2" do
    test "upserts an existing calendar by id without touching its id" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://old/cal.ics"})

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Family (renamed)",
            "ical_url" => "https://new/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, %{calendars_restored: 1}} =
               Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_calendar!(cal.id)
      assert reloaded.id == cal.id
      assert reloaded.name == "Family (renamed)"
      assert reloaded.ical_url == "https://new/cal.ics"
    end

    test "inserts a calendar not yet in the database" do
      new_id = Ash.UUID.generate()

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => new_id,
            "name" => "New",
            "ical_url" => "https://new/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)
      assert Dashboard.get_calendar!(new_id).name == "New"
    end

    test "resets a restored calendar's sync status" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      Dashboard.update_calendar!(cal, %{
        last_error: "boom",
        last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Family",
            "ical_url" => "https://x/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_calendar!(cal.id)
      assert is_nil(reloaded.last_error)
      assert is_nil(reloaded.last_synced_at)
    end

    test "leaves a calendar not present in the backup untouched" do
      untouched = Dashboard.create_calendar!(%{name: "Untouched", ical_url: "https://x/u.ics"})

      backup = Backup.export() |> put_in(["calendars"], []) |> Jason.encode!()

      assert {:ok, %{calendars_restored: 0}} =
               Backup.import_json(backup, skip_safety_export: true)

      assert Dashboard.get_calendar!(untouched.id).name == "Untouched"
    end

    test "updates the singleton setting and resets its status fields" do
      {:ok, setting} = Dashboard.current_setting()

      Dashboard.record_weather_status!(setting, %{
        weather_last_error: "boom",
        weather_last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      backup =
        Backup.export()
        |> put_in(["setting"], %{
          "latitude" => 10.0,
          "longitude" => 20.0,
          "city_label" => "Testville",
          "units" => "metric",
          "greeting" => "Hi",
          "time_zone" => "America/Chicago",
          "calendar_sync_minutes" => 15,
          "weather_refresh_minutes" => 15,
          "daily_refresh_minutes" => 60,
          "sync_max_attempts" => 3
        })
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.current_setting!()
      assert reloaded.city_label == "Testville"
      assert is_nil(reloaded.weather_last_error)
      assert is_nil(reloaded.weather_last_attempted_at)
    end

    test "restores the alert-filtering and news-ticker setting fields" do
      backup =
        Backup.export()
        |> put_in(["setting", "alerts_min_severity"], "severe")
        |> put_in(["setting", "alerts_hidden_categories"], "small craft advisory")
        |> put_in(["setting", "alerts_always_show_categories"], "heat,flood")
        |> put_in(["setting", "alerts_show_body"], true)
        |> put_in(["setting", "news_refresh_minutes"], 30)
        |> put_in(["setting", "news_retention_hours"], 48)
        |> put_in(["setting", "news_ticker_chars_per_second"], 20)
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.current_setting!()
      assert reloaded.alerts_min_severity == "severe"
      assert reloaded.alerts_hidden_categories == "small craft advisory"
      assert reloaded.alerts_always_show_categories == "heat,flood"
      assert reloaded.alerts_show_body == true
      assert reloaded.news_refresh_minutes == 30
      assert reloaded.news_retention_hours == 48
      assert reloaded.news_ticker_chars_per_second == 20
    end

    test "upserts an existing news feed by id without touching its id" do
      feed = Dashboard.create_news_feed!(%{url: "https://old/feed.xml", label: "Old"})

      backup =
        Backup.export()
        |> put_in(["news_feeds"], [
          %{
            "id" => feed.id,
            "url" => "https://new/feed.xml",
            "label" => "New label",
            "enabled" => false
          }
        ])
        |> Jason.encode!()

      assert {:ok, %{news_feeds_restored: 1}} =
               Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_news_feed!(feed.id)
      assert reloaded.id == feed.id
      assert reloaded.url == "https://new/feed.xml"
      assert reloaded.label == "New label"
      assert reloaded.enabled == false
    end

    test "inserts a news feed not yet in the database" do
      new_id = Ash.UUID.generate()

      backup =
        Backup.export()
        |> put_in(["news_feeds"], [
          %{"id" => new_id, "url" => "https://new/feed.xml", "label" => "New", "enabled" => true}
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)
      assert Dashboard.get_news_feed!(new_id).label == "New"
    end

    test "resets a restored news feed's fetch status" do
      feed = Dashboard.create_news_feed!(%{url: "https://x/feed.xml", label: "Local"})

      Dashboard.update_news_feed!(feed, %{
        last_error: "boom",
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      backup =
        Backup.export()
        |> put_in(["news_feeds"], [
          %{"id" => feed.id, "url" => "https://x/feed.xml", "label" => "Local", "enabled" => true}
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_news_feed!(feed.id)
      assert is_nil(reloaded.last_error)
      assert is_nil(reloaded.last_fetched_at)
    end

    test "leaves a news feed not present in the backup untouched" do
      untouched = Dashboard.create_news_feed!(%{url: "https://x/u.xml", label: "Untouched"})

      backup = Backup.export() |> put_in(["news_feeds"], []) |> Jason.encode!()

      assert {:ok, %{news_feeds_restored: 0}} =
               Backup.import_json(backup, skip_safety_export: true)

      assert Dashboard.get_news_feed!(untouched.id).label == "Untouched"
    end

    test "restores a pre-news-feeds backup (missing the news_feeds key) without crashing" do
      untouched = Dashboard.create_news_feed!(%{url: "https://x/u.xml", label: "Untouched"})

      backup = Backup.export() |> Map.delete("news_feeds") |> Jason.encode!()

      assert {:ok, %{news_feeds_restored: 0}} =
               Backup.import_json(backup, skip_safety_export: true)

      assert Dashboard.get_news_feed!(untouched.id).label == "Untouched"
    end

    test "rejects an unsupported version" do
      bad = Backup.export() |> Map.put("version", 99) |> Jason.encode!()

      assert {:error, {:invalid_backup, _}} = Backup.import_json(bad, skip_safety_export: true)
    end

    test "rejects malformed JSON" do
      assert {:error, %Jason.DecodeError{}} =
               Backup.import_json("not json", skip_safety_export: true)
    end

    test "auto-exports the current state to disk before restoring, by default" do
      original_dir = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original_dir) end)

      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      backup = Backup.export_json()

      assert {:ok, _} = Backup.import_json(backup)
      assert File.ls!(@tmp_dir) != []
    end
  end
end
