defmodule FamilyDashboard.WeatherReaper do
  @moduledoc """
  Deletes old `WeatherReading` rows (and their `WeatherHourly`/`WeatherDaily`/
  `WeatherAlert` children) on a daily cron schedule (see `config/config.exs`).
  Only the latest reading is ever read anywhere in the app — everything older
  is pure accumulated history with no read path.

  The current latest reading is always protected, even if it's older than the
  retention window: if refreshes break for an extended period, the dashboard
  should keep showing the last-known (stale) reading rather than reaping down
  to nothing.
  """

  require Ash.Query

  alias FamilyDashboard.{Dashboard, WeatherAlert, WeatherDaily, WeatherHourly, WeatherReading}

  @retention_hours 48

  @doc "Deletes readings older than the retention window, protecting the latest one."
  @spec reap() :: :ok
  def reap do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_hours, :hour)
    protected_id = latest_reading_id()

    reap_query =
      WeatherReading
      |> Ash.Query.filter(observed_at < ^cutoff)
      |> exclude_protected(protected_id)

    {:ok, _} =
      FamilyDashboard.Repo.transaction(fn ->
        ids = reap_query |> Ash.read!() |> Enum.map(& &1.id)

        unless ids == [] do
          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherHourly, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherDaily, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherAlert, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(reap_query, :destroy, %{}, strategy: [:stream])
        end
      end)

    :ok
  end

  defp latest_reading_id do
    case Dashboard.latest_weather() do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp exclude_protected(query, nil), do: query
  defp exclude_protected(query, id), do: Ash.Query.filter(query, id != ^id)
end
