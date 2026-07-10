defmodule FamilyDashboard.WorkersTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.{CalendarSync, WeatherRefresh}

  test "CalendarSync cancels when the calendar no longer exists" do
    # Also exercises the atom -> JSON string key handoff ("calendar_id").
    assert {:cancel, :calendar_not_found} =
             perform_job(CalendarSync, %{"calendar_id" => Ash.UUID.generate()})
  end

  test "WeatherRefresh cancels when no API key is configured" do
    original = Application.get_env(:family_dashboard, :openweather_api_key)
    Application.put_env(:family_dashboard, :openweather_api_key, nil)
    on_exit(fn -> Application.put_env(:family_dashboard, :openweather_api_key, original) end)

    assert {:cancel, :no_api_key} = perform_job(WeatherRefresh, %{})
  end
end
