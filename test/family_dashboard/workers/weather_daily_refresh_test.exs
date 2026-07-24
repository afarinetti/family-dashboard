defmodule FamilyDashboard.Workers.WeatherDailyRefreshTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.{Dashboard, Workers.WeatherDailyRefresh}

  test "cancels when no location is configured" do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{latitude: nil, longitude: nil})

    assert {:cancel, :no_location} = perform_job(WeatherDailyRefresh, %{})
  end

  test "cancels when no API key is configured" do
    original_provider = Application.get_env(:family_dashboard, :weather_provider)
    original_key = Application.get_env(:family_dashboard, :openweather_api_key)
    Application.put_env(:family_dashboard, :weather_provider, FamilyDashboard.Weather.OpenWeather)
    Application.put_env(:family_dashboard, :openweather_api_key, nil)

    on_exit(fn ->
      Application.put_env(:family_dashboard, :weather_provider, original_provider)
      Application.put_env(:family_dashboard, :openweather_api_key, original_key)
    end)

    assert {:cancel, :no_api_key} = perform_job(WeatherDailyRefresh, %{})
  end
end
