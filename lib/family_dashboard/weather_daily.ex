defmodule FamilyDashboard.WeatherDaily do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_daily"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :forecast_date,
        :high,
        :low,
        :pop,
        :summary,
        :humidity,
        :wind_speed,
        :sunrise,
        :sunset,
        :icon,
        :condition,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    attribute :forecast_date, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :high, :float do
      public? true
    end

    attribute :low, :float do
      public? true
    end

    attribute :pop, :float do
      public? true
    end

    attribute :summary, :string do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :sunrise, :utc_datetime do
      public? true
    end

    attribute :sunset, :utc_datetime do
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
