defmodule FamilyDashboard.Workers.WeatherRefresh do
  @moduledoc "Refreshes the weather reading. Enqueued by the heartbeat when due."

  use Oban.Worker,
    queue: :default,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias FamilyDashboard.Sync

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Sync.refresh_weather() do
      :ok -> :ok
      {:error, :no_location} -> {:cancel, :no_location}
      {:error, :no_api_key} -> {:cancel, :no_api_key}
      {:error, _reason} = error -> error
    end
  end
end
