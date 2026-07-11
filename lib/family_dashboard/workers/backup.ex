defmodule FamilyDashboard.Workers.Backup do
  @moduledoc """
  Writes a dated JSON backup of `calendars` + `settings` to disk on a daily
  cron schedule (see `config/config.exs`). Independent of the heartbeat's
  due-gating — a backup must run on a fixed cadence even before the `Setting`
  singleton is seeded.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.Backup

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Backup.export_json() |> Backup.write_to_disk() do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
