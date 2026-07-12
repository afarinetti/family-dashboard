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

    test "hidden categories and show-body are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 alerts_hidden_categories: "small craft advisory,air quality",
                 alerts_show_body: true
               })

      assert updated.alerts_hidden_categories == "small craft advisory,air quality"
      assert updated.alerts_show_body == true
    end
  end
end
