defmodule FamilyDashboard.Workers.EventReap do
  @moduledoc """
  Reaps old events on a daily cron schedule (see `config/config.exs`),
  alongside the weather reap, news reap, and backup jobs. See
  `FamilyDashboard.EventReaper` for the retention policy.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.EventReaper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    EventReaper.reap()
  end
end
