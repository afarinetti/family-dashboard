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
      define :upsert_calendar, action: :upsert
    end

    resource FamilyDashboard.Event do
      define :events_in_window, action: :in_window, args: [:from, :to]
      define :create_event, action: :create
    end

    resource FamilyDashboard.WeatherReading do
      define :latest_weather, action: :latest, not_found_error?: false
      define :record_weather, action: :create
      define :update_weather_reading, action: :update
    end

    resource FamilyDashboard.WeatherHourly do
      define :create_weather_hourly, action: :create
    end

    resource FamilyDashboard.WeatherDaily do
      define :create_weather_daily, action: :create
      define :list_weather_daily, action: :read
    end

    resource FamilyDashboard.WeatherAlert do
      define :create_weather_alert, action: :create
      define :list_weather_alerts, action: :read
    end

    resource FamilyDashboard.Setting do
      define :current_setting, action: :current, not_found_error?: false
      define :create_setting, action: :create
      define :update_setting, action: :update
      define :record_weather_status, action: :record_weather_status
    end

    resource FamilyDashboard.NewsFeed do
      define :list_news_feeds, action: :read
      define :get_news_feed, action: :read, get_by: [:id]
      define :create_news_feed, action: :create
      define :update_news_feed, action: :update
      define :destroy_news_feed, action: :destroy
    end

    resource FamilyDashboard.NewsItem do
      define :create_news_item, action: :create
      define :list_news_items, action: :read
    end
  end
end
