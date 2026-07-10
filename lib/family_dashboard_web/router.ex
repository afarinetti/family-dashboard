defmodule FamilyDashboardWeb.Router do
  use FamilyDashboardWeb, :router

  import Oban.Web.Router
  import AshAdmin.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FamilyDashboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Shared-password gate for the settings/admin area. The public dashboard is
  # intentionally NOT behind this — the wall display must never hit a login.
  pipeline :settings_area do
    plug FamilyDashboardWeb.Plugs.SettingsAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FamilyDashboardWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  # Settings/admin — source management (calendars, location, scheduling) and job
  # monitoring. Available in all environments, behind the password gate.
  scope "/" do
    pipe_through [:browser, :settings_area]

    ash_admin "/admin"
    oban_dashboard("/oban")
  end

  # Other scopes may use custom stacks.
  # scope "/api", FamilyDashboardWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:family_dashboard, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FamilyDashboardWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
