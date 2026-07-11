defmodule FamilyDashboardWeb.BackupControllerTest do
  use FamilyDashboardWeb.ConnCase

  alias FamilyDashboard.Dashboard

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  test "requires the settings password", %{conn: conn} do
    conn = get(conn, "/ops/backup.json")
    assert conn.status == 401
  end

  test "returns the current backup as a JSON download", %{conn: conn} do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    conn =
      conn
      |> put_req_header("authorization", @auth)
      |> get("/ops/backup.json")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"

    assert {:ok, decoded} = Jason.decode(conn.resp_body)
    assert decoded["version"] == 1
    assert [%{"name" => "Family"}] = decoded["calendars"]
  end
end
