defmodule FamilyDashboardWeb.BackupController do
  @moduledoc """
  Serves the current calendars/settings backup as a JSON file download — kept
  out of the ops LiveView's socket so a large export doesn't round-trip
  through the websocket connection.
  """
  use FamilyDashboardWeb, :controller

  alias FamilyDashboard.Backup

  def download(conn, _params) do
    filename = "family_dashboard_backup_#{Date.utc_today()}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, Backup.export_json())
  end
end
