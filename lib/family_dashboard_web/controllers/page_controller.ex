defmodule FamilyDashboardWeb.PageController do
  use FamilyDashboardWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
