defmodule FamilyDashboard.WeatherReading do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_readings"
    repo FamilyDashboard.Repo
  end

  actions do
    # The most recent reading; the dashboard renders this one. Loads its
    # forecast children so callers never need a second query for the
    # 8-hour/7-day widgets.
    read :latest do
      get? true

      prepare build(
                sort: [observed_at: :desc, inserted_at: :desc],
                limit: 1,
                load: [:hourly, :daily, :alerts]
              )
    end

    @fields [
      :observed_at,
      :temp,
      :feels_like,
      :condition,
      :icon,
      :high,
      :low,
      :humidity,
      :pressure,
      :dew_point,
      :uvi,
      :clouds,
      :visibility,
      :wind_speed,
      :wind_deg,
      :wind_gust,
      :sunrise,
      :sunset,
      :location_label
    ]

    defaults [:read, :destroy, create: @fields]

    # Non-atomic: kept from the original resource since callers pass a full
    # attrs map, not an atomic-safe expression update.
    update :update do
      primary? true
      require_atomic? false
      accept @fields
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :observed_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :temp, :float do
      public? true
    end

    attribute :feels_like, :float do
      public? true
    end

    attribute :condition, :string do
      public? true
    end

    attribute :icon, :string do
      public? true
    end

    attribute :high, :float do
      public? true
    end

    attribute :low, :float do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :pressure, :integer do
      public? true
    end

    attribute :dew_point, :float do
      public? true
    end

    attribute :uvi, :float do
      public? true
    end

    attribute :clouds, :integer do
      public? true
    end

    attribute :visibility, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :wind_deg, :integer do
      public? true
    end

    attribute :wind_gust, :float do
      public? true
    end

    attribute :sunrise, :utc_datetime do
      public? true
    end

    attribute :sunset, :utc_datetime do
      public? true
    end

    attribute :location_label, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :hourly, FamilyDashboard.WeatherHourly do
      destination_attribute :weather_reading_id
      sort forecast_time: :asc
    end

    has_many :daily, FamilyDashboard.WeatherDaily do
      destination_attribute :weather_reading_id
      sort forecast_date: :asc
    end

    has_many :alerts, FamilyDashboard.WeatherAlert do
      destination_attribute :weather_reading_id
      sort priority: :asc
    end
  end
end
