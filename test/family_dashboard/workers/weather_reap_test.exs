defmodule FamilyDashboard.Workers.WeatherReapTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.WeatherReap

  test "delegates to WeatherReaper.reap/0" do
    assert :ok = perform_job(WeatherReap, %{})
  end
end
