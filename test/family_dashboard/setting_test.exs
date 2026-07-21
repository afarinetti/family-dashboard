defmodule FamilyDashboard.SettingTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp setting do
    {:ok, setting} = Dashboard.current_setting()
    setting
  end

  describe "time_zone validation" do
    test "rejects an invalid IANA time zone" do
      assert {:error, _} = Dashboard.update_setting(setting(), %{time_zone: "Not/AZone"})
    end

    test "accepts a valid IANA time zone" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{time_zone: "America/New_York"})

      assert updated.time_zone == "America/New_York"
    end
  end

  describe "alerts_min_severity validation" do
    test "rejects an invalid severity" do
      assert {:error, _} =
               Dashboard.update_setting(setting(), %{alerts_min_severity: "extreme-ish"})
    end

    test "accepts a valid severity" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{alerts_min_severity: "severe"})

      assert updated.alerts_min_severity == "severe"
    end
  end

  describe "alert filter settings" do
    test "default to moderate severity, no hidden categories, and compact display" do
      assert setting().alerts_min_severity == "moderate"
      assert setting().alerts_hidden_categories == ""
      assert setting().alerts_show_body == false
    end

    test "defaults to a life-safety always-show category list" do
      assert setting().alerts_always_show_categories ==
               "heat,flood,tornado,hurricane,tropical,tsunami,fire,wind,winter,freeze,coastal,marine"
    end

    test "hidden categories and show-body are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 alerts_hidden_categories: "small craft advisory,air quality",
                 alerts_show_body: true
               })

      assert updated.alerts_hidden_categories == "small craft advisory,air quality"
      assert updated.alerts_show_body == true
    end

    test "always-show categories are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 alerts_always_show_categories: "heat,flood"
               })

      assert updated.alerts_always_show_categories == "heat,flood"
    end
  end

  describe "news scheduling settings" do
    test "default to a 15 minute refresh and 24 hour retention" do
      assert setting().news_refresh_minutes == 15
      assert setting().news_retention_hours == 24
      assert setting().news_last_attempted_at == nil
    end

    test "news_refresh_minutes and news_retention_hours are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 news_refresh_minutes: 30,
                 news_retention_hours: 12
               })

      assert updated.news_refresh_minutes == 30
      assert updated.news_retention_hours == 12
    end

    test "record_news_attempt stamps news_last_attempted_at" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, updated} =
               Dashboard.record_news_attempt(setting(), %{news_last_attempted_at: now})

      assert updated.news_last_attempted_at == now
    end
  end
end
