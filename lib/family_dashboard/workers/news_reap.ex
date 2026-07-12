defmodule FamilyDashboard.Workers.NewsReap do
  @moduledoc """
  Reaps old news items on a daily cron schedule (see `config/config.exs`),
  alongside the weather reap and backup jobs. See `FamilyDashboard.NewsReaper`
  for the retention policy.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.NewsReaper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    NewsReaper.reap()
  end
end
