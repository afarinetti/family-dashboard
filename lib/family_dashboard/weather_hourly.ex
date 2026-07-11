defmodule FamilyDashboard.WeatherHourly do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_hourly"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :forecast_time,
        :temp,
        :feels_like,
        :pop,
        :humidity,
        :wind_speed,
        :icon,
        :condition,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    attribute :forecast_time, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :temp, :float do
      public? true
    end

    attribute :feels_like, :float do
      public? true
    end

    attribute :pop, :float do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :icon, :string do
      public? true
    end

    attribute :condition, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :weather_reading, FamilyDashboard.WeatherReading do
      allow_nil? false
      attribute_writable? true
    end
  end
end
