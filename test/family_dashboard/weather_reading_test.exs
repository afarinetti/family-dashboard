defmodule FamilyDashboard.WeatherReadingTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  test "accepts the widened set of current-conditions fields" do
    assert {:ok, reading} =
             Dashboard.record_weather(%{
               observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
               temp: 70.0,
               feels_like: 68.0,
               condition: "clear sky",
               icon: "01d",
               humidity: 55,
               pressure: 1013,
               dew_point: 60.1,
               uvi: 3.2,
               clouds: 75,
               visibility: 10_000,
               wind_speed: 8.5,
               wind_deg: 210,
               wind_gust: 12.0,
               sunrise: DateTime.utc_now() |> DateTime.truncate(:second),
               sunset: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert reading.humidity == 55
    assert reading.wind_speed == 8.5
  end

  test "latest_weather loads hourly (asc) and daily (asc) associations" do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    later = DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.truncate(:second)
    sooner = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)

    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: later,
      temp: 72.0
    })

    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: sooner,
      temp: 71.0
    })

    loaded = Dashboard.latest_weather!()
    assert Enum.map(loaded.hourly, & &1.forecast_time) == [sooner, later]
    assert loaded.daily == []
  end
end
