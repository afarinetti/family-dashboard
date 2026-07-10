defmodule FamilyDashboardWeb.SettingsAuthTest do
  use FamilyDashboardWeb.ConnCase

  # Matches the dev/test defaults set in config/runtime.exs.
  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  test "the public dashboard is open (no auth)", %{conn: conn} do
    conn = get(conn, "/")
    assert conn.status == 200
  end

  test "the settings/admin area is rejected without credentials", %{conn: conn} do
    conn = get(conn, "/admin")
    assert conn.status == 401
  end

  test "the settings/admin area is reachable with the shared password", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", @auth)
      |> get("/admin")

    refute conn.status == 401
  end
end
