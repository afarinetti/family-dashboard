defmodule FamilyDashboard.EventReaper do
  @moduledoc """
  Deletes `Event` rows whose start is comfortably past the agenda's display
  window on a daily cron (see `config/config.exs`). The agenda over-fetches to
  `today-1` UTC and regroups by local date, so anything older than the
  retention window is never displayed and never re-materialized by sync —
  safe to delete unconditionally. Closes the sync prune's lower-bound gap
  (`Sync.replace_window_events/4` only reaps `starts_at >= today`), so
  source-deleted past/all-day/multi-day events stop accumulating.
  """

  require Ash.Query

  alias FamilyDashboard.Event

  # 2 days — safe margin over the agenda's 1-day over-fetch.
  @retention_hours 48

  @doc "Deletes events whose start is older than the retention window."
  @spec reap() :: :ok
  def reap do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_hours, :hour)

    Event
    |> Ash.Query.filter(starts_at < ^cutoff)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: [:stream])

    :ok
  end
end
