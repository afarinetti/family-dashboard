defmodule FamilyDashboard.Workers.NewsRefresh do
  @moduledoc "Refreshes all enabled news feeds. Enqueued by the heartbeat when due."

  use Oban.Worker,
    queue: :default,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias FamilyDashboard.News

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    News.refresh_all()
  end
end
