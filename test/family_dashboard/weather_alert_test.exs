defmodule FamilyDashboard.WeatherAlertTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates an alert row attached to a reading" do
    reading = create_reading()

    assert {:ok, alert} =
             Dashboard.create_weather_alert(%{
               weather_reading_id: reading.id,
               severity: "severe",
               alert_type: "AW.TS.SV",
               priority: 2,
               category: "thunderstorm",
               name: "Severe Thunderstorm Warning",
               body: "A severe thunderstorm warning has been issued.",
               color: "FFA500",
               emergency: false,
               begins_at: DateTime.utc_now() |> DateTime.truncate(:second),
               expires_at:
                 DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
               issued_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert alert.weather_reading_id == reading.id
    assert alert.severity == "severe"
    assert alert.name == "Severe Thunderstorm Warning"
  end

  test "requires severity" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_alert(%{weather_reading_id: reading.id, name: "Test"})
  end

  test "latest_weather loads alerts sorted by priority ascending" do
    reading = create_reading()

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "minor",
      priority: 4,
      name: "Minor advisory"
    })

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "extreme",
      priority: 1,
      name: "Extreme warning"
    })

    loaded = Dashboard.latest_weather!()
    assert Enum.map(loaded.alerts, & &1.name) == ["Extreme warning", "Minor advisory"]
  end
end
