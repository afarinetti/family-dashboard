defmodule FamilyDashboard.WeatherHourlyTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates an hourly row attached to a reading" do
    reading = create_reading()

    assert {:ok, hourly} =
             Dashboard.create_weather_hourly(%{
               weather_reading_id: reading.id,
               forecast_time: DateTime.utc_now() |> DateTime.truncate(:second),
               temp: 71.0,
               icon: "01d"
             })

    assert hourly.weather_reading_id == reading.id
    assert hourly.temp == 71.0
  end

  test "requires forecast_time" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_hourly(%{weather_reading_id: reading.id, temp: 71.0})
  end
end
