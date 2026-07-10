defmodule FamilyDashboard.Workers.CalendarSync do
  @moduledoc "Syncs one calendar's feed. Enqueued by the heartbeat for due calendars."

  # Uniqueness prevents the every-minute heartbeat from piling up duplicate jobs
  # while a sync is still pending/running.
  use Oban.Worker,
    queue: :default,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias FamilyDashboard.{Dashboard, Sync}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_id" => calendar_id}}) do
    case Dashboard.get_calendar(calendar_id) do
      {:ok, calendar} -> Sync.sync_calendar(calendar)
      {:error, _not_found} -> {:cancel, :calendar_not_found}
    end
  end
end
