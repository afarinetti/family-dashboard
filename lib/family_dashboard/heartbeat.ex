defmodule FamilyDashboard.Heartbeat do
  @moduledoc """
  The fixed-cadence tick (driven by an ash_oban scheduled action every minute).

  It reads the live `Setting` row and enqueues sync work only for what is
  actually *due* per the configured intervals — so the effective sync cadence
  and retry count are editable in the settings panel without a redeploy.
  """

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, WeatherRefresh}

  # Fallbacks when the singleton Setting row hasn't been created yet.
  @default_calendar_minutes 15
  @default_weather_minutes 30
  @default_max_attempts 3

  @spec run() :: :ok
  def run do
    setting = current_setting()
    now = DateTime.utc_now()

    enqueue_due_calendars(setting, now)
    enqueue_weather_if_due(setting, now)
    :ok
  end

  defp enqueue_due_calendars(setting, now) do
    interval = minutes(setting, :calendar_sync_minutes, @default_calendar_minutes) * 60
    max_attempts = attempts(setting)

    Dashboard.list_calendars!()
    |> Enum.filter(& &1.active)
    |> Enum.filter(&calendar_due?(&1, now, interval))
    |> Enum.each(fn calendar ->
      %{calendar_id: calendar.id}
      |> CalendarSync.new(max_attempts: max_attempts)
      |> Oban.insert()
    end)
  end

  defp enqueue_weather_if_due(setting, now) do
    interval = minutes(setting, :weather_refresh_minutes, @default_weather_minutes) * 60

    if weather_due?(now, interval) do
      %{}
      |> WeatherRefresh.new(max_attempts: attempts(setting))
      |> Oban.insert()
    end
  end

  defp calendar_due?(%{last_synced_at: nil}, _now, _interval), do: true

  defp calendar_due?(%{last_synced_at: last_synced_at}, now, interval) do
    DateTime.diff(now, last_synced_at) >= interval
  end

  defp weather_due?(now, interval) do
    case Dashboard.latest_weather() do
      {:ok, nil} -> true
      {:ok, reading} -> DateTime.diff(now, reading.inserted_at) >= interval
      _ -> true
    end
  end

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  defp minutes(nil, _key, default), do: default
  defp minutes(setting, key, default), do: Map.get(setting, key) || default

  defp attempts(nil), do: @default_max_attempts
  defp attempts(setting), do: setting.sync_max_attempts || @default_max_attempts
end
