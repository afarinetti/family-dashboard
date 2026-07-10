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
    # The test environment sets no WEATHER_API_KEY.
    assert {:cancel, :no_api_key} = perform_job(WeatherRefresh, %{})
  end
end
