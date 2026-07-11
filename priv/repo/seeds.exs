# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FamilyDashboard.Repo.insert!(%FamilyDashboard.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias FamilyDashboard.Dashboard

# Ensure the singleton Setting row exists. Values are placeholders meant to be
# edited in the settings admin (location drives the weather panel).
case Dashboard.current_setting() do
  {:ok, nil} ->
    Dashboard.create_setting!(%{
      latitude: 41.8781,
      longitude: -87.6298,
      city_label: "Chicago",
      units: "imperial",
      time_zone: "America/Chicago",
      weather_refresh_minutes: 15,
      greeting: "Welcome home"
    })

  {:ok, _setting} ->
    :ok
end
