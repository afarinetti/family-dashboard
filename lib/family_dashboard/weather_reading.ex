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
    # The most recent reading; the dashboard renders this one.
    read :latest do
      get? true
      prepare build(sort: [observed_at: :desc], limit: 1)
    end

    @fields [
      :observed_at,
      :temp,
      :feels_like,
      :condition,
      :icon,
      :high,
      :low,
      :forecast,
      :location_label
    ]

    defaults [:read, :destroy, create: @fields]

    # Non-atomic: the `forecast` map can't be bound as a raw SQL param in an
    # atomic update (SQLite). Used by the daily job to patch days/high/low.
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

    attribute :forecast, :map do
      public? true
    end

    attribute :location_label, :string do
      public? true
    end

    timestamps()
  end
end
