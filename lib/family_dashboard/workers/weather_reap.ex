defmodule FamilyDashboard.Workers.WeatherReap do
  @moduledoc """
  Reaps old weather readings on a daily cron schedule (see
  `config/config.exs`), alongside the backup job. See
  `FamilyDashboard.WeatherReaper` for the retention policy.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.WeatherReaper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    WeatherReaper.reap()
  end
end
