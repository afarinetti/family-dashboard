defmodule FamilyDashboard.Dashboard do
  use Ash.Domain,
    otp_app: :family_dashboard,
    extensions: [AshAdmin.Domain]

  # Surfaces this domain and its resources in the gated ash_admin settings UI.
  admin do
    show? true
  end

  resources do
    resource FamilyDashboard.Calendar do
      define :list_calendars, action: :read
      define :get_calendar, action: :read, get_by: [:id]
      define :create_calendar, action: :create
      define :update_calendar, action: :update
      define :destroy_calendar, action: :destroy
    end

    resource FamilyDashboard.Event do
      define :events_in_window, action: :in_window, args: [:from, :to]
      define :create_event, action: :create
    end

    resource FamilyDashboard.WeatherReading do
      define :latest_weather, action: :latest, not_found_error?: false
      define :record_weather, action: :create
    end

    resource FamilyDashboard.Setting do
      define :current_setting, action: :current, not_found_error?: false
      define :create_setting, action: :create
      define :update_setting, action: :update
    end
  end
end
