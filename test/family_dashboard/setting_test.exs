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
end
