defmodule FamilyDashboardWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import FamilyDashboardWeb.CoreComponents, only: [relative_time: 1]

  describe "relative_time/1" do
    test "nil is never" do
      assert relative_time(nil) == "never"
    end

    test "under a minute is just now" do
      assert relative_time(DateTime.utc_now()) == "just now"
    end

    test "minutes ago" do
      dt = DateTime.utc_now() |> DateTime.add(-5, :minute)
      assert relative_time(dt) == "5m ago"
    end

    test "hours ago" do
      dt = DateTime.utc_now() |> DateTime.add(-3, :hour)
      assert relative_time(dt) == "3h ago"
    end

    test "days ago" do
      dt = DateTime.utc_now() |> DateTime.add(-2, :day)
      assert relative_time(dt) == "2d ago"
    end
  end
end
