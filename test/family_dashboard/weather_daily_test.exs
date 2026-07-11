defmodule FamilyDashboard.WeatherDailyTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates a daily row attached to a reading" do
    reading = create_reading()

    assert {:ok, daily} =
             Dashboard.create_weather_daily(%{
               weather_reading_id: reading.id,
               forecast_date: DateTime.utc_now() |> DateTime.truncate(:second),
               high: 80.0,
               low: 60.0
             })

    assert daily.weather_reading_id == reading.id
    assert daily.high == 80.0
  end

  test "requires forecast_date" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_daily(%{weather_reading_id: reading.id, high: 80.0})
  end
end
