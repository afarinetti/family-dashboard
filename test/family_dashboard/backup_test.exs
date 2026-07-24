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
    test "includes version, calendars, and the singleton setting" do
      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      data = Backup.export()

      assert data["version"] == 1
      assert data["exported_at"]
      assert [%{"name" => "Family", "ical_url" => "https://x/cal.ics"}] = data["calendars"]
      assert data["setting"]["time_zone"]
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

  describe "list_backups/0" do
    test "returns [] when the backup dir doesn't exist yet" do
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original) end)

      assert Backup.list_backups() == []
    end

    test "lists only .json files, newest first" do
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original) end)

      File.mkdir_p!(@tmp_dir)
      File.write!(Path.join(@tmp_dir, "older.json"), "{}")
      File.touch!(Path.join(@tmp_dir, "older.json"), {{2020, 1, 1}, {0, 0, 0}})
      File.write!(Path.join(@tmp_dir, "newer.json"), "{}")
      File.touch!(Path.join(@tmp_dir, "newer.json"), {{2024, 1, 1}, {0, 0, 0}})
      File.write!(Path.join(@tmp_dir, "ignored.txt"), "nope")

      assert [%{filename: "newer.json"}, %{filename: "older.json"}] = Backup.list_backups()
    end
  end

  describe "read_backup/1" do
    test "reads a file from the configured backup dir by basename" do
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original) end)

      File.mkdir_p!(@tmp_dir)
      File.write!(Path.join(@tmp_dir, "backup.json"), ~s({"ok":true}))

      assert {:ok, ~s({"ok":true})} = Backup.read_backup("backup.json")
    end

    test "reduces a path-traversal attempt to its basename, staying inside backup_dir" do
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original) end)

      assert {:error, :enoent} = Backup.read_backup("../../etc/passwd")
    end

    test "returns an error for a missing file" do
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original) end)

      assert {:error, :enoent} = Backup.read_backup("missing.json")
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
