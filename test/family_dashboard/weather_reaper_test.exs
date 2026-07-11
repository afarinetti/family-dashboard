defmodule FamilyDashboard.WeatherReaperTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, WeatherReaper}

  defp create_reading(observed_at) do
    Dashboard.record_weather!(%{observed_at: observed_at, temp: 70.0})
  end

  defp add_hourly(reading) do
    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: reading.observed_at,
      temp: 70.0
    })
  end

  defp add_daily(reading) do
    Dashboard.create_weather_daily!(%{
      weather_reading_id: reading.id,
      forecast_date: reading.observed_at,
      high: 80.0,
      low: 60.0
    })
  end

  defp reading_ids do
    FamilyDashboard.WeatherReading |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes readings older than 48 hours, along with their hourly/daily children" do
    old =
      create_reading(DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second))

    add_hourly(old)
    add_daily(old)

    recent = create_reading(DateTime.utc_now() |> DateTime.truncate(:second))
    recent_hourly = add_hourly(recent)
    recent_daily = add_daily(recent)

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [recent.id]
    assert FamilyDashboard.WeatherHourly |> Ash.read!() |> Enum.map(& &1.id) == [recent_hourly.id]
    assert FamilyDashboard.WeatherDaily |> Ash.read!() |> Enum.map(& &1.id) == [recent_daily.id]
  end

  test "keeps readings within the retention window" do
    within_window =
      create_reading(DateTime.utc_now() |> DateTime.add(-10, :hour) |> DateTime.truncate(:second))

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [within_window.id]
  end

  test "always protects the latest reading, even if it's older than the window" do
    only_reading =
      create_reading(DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second))

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [only_reading.id]
  end

  test "does nothing when there are no readings" do
    assert :ok = WeatherReaper.reap()
    assert reading_ids() == []
  end
end
