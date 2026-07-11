defmodule FamilyDashboard.Workers.WeatherDailyRefresh do
  @moduledoc """
  Refreshes the 7-day forecast on its own schedule. Separate from the
  current+hourly refresh because OWM's daily endpoint is slow and flaky — this
  job retries more (3 attempts) without stalling the fast weather updates.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 900,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias FamilyDashboard.Sync

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Sync.refresh_daily() do
      :ok -> :ok
      {:error, :no_location} -> {:cancel, :no_location}
      {:error, :no_api_key} -> {:cancel, :no_api_key}
      {:error, :no_reading} -> {:cancel, :no_reading}
      {:error, _reason} = error -> error
    end
  end
end
