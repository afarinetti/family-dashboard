defmodule FamilyDashboardWeb.OpsLiveTest do
  use FamilyDashboardWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FamilyDashboard.Dashboard

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  defp authed(conn), do: put_req_header(conn, "authorization", @auth)

  test "requires the settings password", %{conn: conn} do
    conn = get(conn, "/ops")
    assert conn.status == 401
  end

  test "renders the status panel with the seeded setting and no calendars", %{conn: conn} do
    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Ops"
    assert html =~ "last attempted never"
  end

  test "lists a calendar with its sync status", %{conn: conn} do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Family"
    assert html =~ "synced never"
  end

  test "shows a calendar's last_error in red", %{conn: conn} do
    cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    Dashboard.update_calendar!(cal, %{last_error: "boom"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "boom"
  end
end
