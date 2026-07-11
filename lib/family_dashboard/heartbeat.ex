defmodule FamilyDashboard.Heartbeat do
  @moduledoc """
  The fixed-cadence tick (driven by an ash_oban scheduled action every minute).

  It reads the live `Setting` row and enqueues sync work only for what is
  actually *due* per the configured intervals — so the effective sync cadence
  and retry count are editable in the settings panel without a redeploy.
  """

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}

  # Fallbacks when the singleton Setting row hasn't been created yet.
  @default_calendar_minutes 15
  @default_weather_minutes 30
  @default_daily_minutes 60
  @default_max_attempts 3

  @spec run() :: :ok
  def run do
    setting = current_setting()
    now = DateTime.utc_now()

    enqueue_due_calendars(setting, now)
    enqueue_weather_if_due(setting, now)
    enqueue_daily_if_due(setting, now)
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

  # No setting row yet → no location, nothing to fetch.
  defp enqueue_weather_if_due(nil, _now), do: :ok

  defp enqueue_weather_if_due(setting, now) do
    interval = minutes(setting, :weather_refresh_minutes, @default_weather_minutes) * 60

    if weather_due?(setting.weather_last_attempted_at, now, interval) do
      # max_attempts: 1 — weather is ephemeral; a failed fetch waits for the next
      # cycle rather than retrying in-cycle and burning the API quota.
      %{}
      |> WeatherRefresh.new(max_attempts: 1)
      |> Oban.insert()
    end
  end

  # The 7-day forecast refreshes on its own, less frequent schedule (the worker
  # itself retries the flaky endpoint).
  defp enqueue_daily_if_due(nil, _now), do: :ok

  defp enqueue_daily_if_due(setting, now) do
    interval = minutes(setting, :daily_refresh_minutes, @default_daily_minutes) * 60

    if weather_due?(setting.daily_last_attempted_at, now, interval) do
      Oban.insert(WeatherDailyRefresh.new(%{}))
    end
  end

  # Gate on the last *attempt* (success or failure) so a broken feed is retried
  # on its interval, not re-enqueued every minute.
  defp calendar_due?(%{last_attempted_at: nil}, _now, _interval), do: true

  defp calendar_due?(%{last_attempted_at: last_attempted_at}, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  # Gate on the last *attempt* (success or failure), not the last successful
  # reading — otherwise a persistently-failing fetch is "due" every minute and
  # hammers the API.
  defp weather_due?(nil, _now, _interval), do: true

  defp weather_due?(last_attempted_at, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
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
