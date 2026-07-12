defmodule FamilyDashboard.Heartbeat do
  @moduledoc """
  The fixed-cadence tick (driven by an ash_oban scheduled action every minute).

  It reads the live `Setting` row and enqueues sync work only for what is
  actually *due* per the configured intervals — so the effective sync cadence
  and retry count are editable in the settings panel without a redeploy.

  `enqueue_weather/1`, `enqueue_daily/1`, `enqueue_news/1`, and
  `enqueue_calendar/3` are also used directly by the ops hub's manual "sync
  now" buttons (`force?: true`), which bypass each worker's Oban uniqueness
  window so a click always enqueues even if a job is already pending — see
  `FamilyDashboardWeb.OpsLive`.
  """

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, NewsRefresh, WeatherDailyRefresh, WeatherRefresh}

  # Fallbacks when the singleton Setting row hasn't been created yet.
  @default_calendar_minutes 15
  @default_weather_minutes 30
  @default_daily_minutes 60
  @default_news_minutes 15
  @default_max_attempts 3

  @spec run() :: :ok
  def run do
    setting = current_setting()
    now = DateTime.utc_now()

    enqueue_due_calendars(setting, now)
    enqueue_weather_if_due(setting, now)
    enqueue_daily_if_due(setting, now)
    enqueue_news_if_due(setting, now)
    :ok
  end

  @doc "Enqueues a weather refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_weather(boolean()) :: :ok
  def enqueue_weather(force? \\ false) do
    # max_attempts: 1 — weather is ephemeral; a failed fetch waits for the next
    # cycle rather than retrying in-cycle and burning the API quota.
    opts = [max_attempts: 1] ++ force_opts(force?)
    %{} |> WeatherRefresh.new(opts) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a daily-forecast refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_daily(boolean()) :: :ok
  def enqueue_daily(force? \\ false) do
    %{} |> WeatherDailyRefresh.new(force_opts(force?)) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a news refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_news(boolean()) :: :ok
  def enqueue_news(force? \\ false) do
    %{} |> NewsRefresh.new(force_opts(force?)) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a sync for one calendar. `force?: true` bypasses the worker's unique window."
  @spec enqueue_calendar(String.t(), pos_integer(), boolean()) :: :ok
  def enqueue_calendar(calendar_id, max_attempts, force? \\ false) do
    opts = [max_attempts: max_attempts] ++ force_opts(force?)
    %{calendar_id: calendar_id} |> CalendarSync.new(opts) |> Oban.insert()
    :ok
  end

  # `unique: false` on `.new/2` bypasses the worker's compile-time unique clause
  # for this single insert, so a manual click always enqueues instead of being
  # silently absorbed by a pending/executing job's uniqueness window.
  defp force_opts(true), do: [unique: false]
  defp force_opts(false), do: []

  defp enqueue_due_calendars(setting, now) do
    interval = minutes(setting, :calendar_sync_minutes, @default_calendar_minutes) * 60
    max_attempts = attempts(setting)

    Dashboard.list_calendars!()
    |> Enum.filter(& &1.active)
    |> Enum.filter(&calendar_due?(&1, now, interval))
    |> Enum.each(&enqueue_calendar(&1.id, max_attempts))
  end

  # No setting row yet — nothing to fetch or record status against.
  defp enqueue_weather_if_due(nil, _now), do: :ok

  defp enqueue_weather_if_due(setting, now) do
    interval = minutes(setting, :weather_refresh_minutes, @default_weather_minutes) * 60

    if attempt_due?(setting.weather_last_attempted_at, now, interval) do
      enqueue_weather()
    end
  end

  # The 7-day forecast refreshes on its own, less frequent schedule (the worker
  # itself retries the flaky endpoint).
  defp enqueue_daily_if_due(nil, _now), do: :ok

  defp enqueue_daily_if_due(setting, now) do
    interval = minutes(setting, :daily_refresh_minutes, @default_daily_minutes) * 60

    if attempt_due?(setting.daily_last_attempted_at, now, interval) do
      enqueue_daily()
    end
  end

  # One worker refreshes every enabled feed together, so there's a single
  # global cadence (news_last_attempted_at) rather than a per-feed one.
  defp enqueue_news_if_due(nil, _now), do: :ok

  defp enqueue_news_if_due(setting, now) do
    interval = minutes(setting, :news_refresh_minutes, @default_news_minutes) * 60

    if attempt_due?(setting.news_last_attempted_at, now, interval) do
      enqueue_news()
    end
  end

  # Gate on the last *attempt* (success or failure) so a broken feed is retried
  # on its interval, not re-enqueued every minute.
  defp calendar_due?(%{last_attempted_at: nil}, _now, _interval), do: true

  defp calendar_due?(%{last_attempted_at: last_attempted_at}, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  # Gate on the last *attempt*, not the last success — otherwise a
  # persistently-failing fetch is "due" every minute and hammers the source.
  # Shared by weather, the daily forecast, and news.
  defp attempt_due?(nil, _now, _interval), do: true

  defp attempt_due?(last_attempted_at, now, interval) do
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
