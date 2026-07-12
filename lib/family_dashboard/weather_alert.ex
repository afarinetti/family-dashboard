defmodule FamilyDashboard.WeatherAlert do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_alerts"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :alert_type,
        :severity,
        :priority,
        :category,
        :name,
        :body,
        :color,
        :emergency,
        :begins_at,
        :expires_at,
        :issued_at,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    # The provider's raw alert code (e.g. Xweather's "AW.TS.MD"), kept for
    # debugging/display — never used for filtering, that's `severity`/`category`.
    attribute :alert_type, :string do
      public? true
    end

    # Normalized to "extreme" | "severe" | "moderate" | "minor" — see
    # FamilyDashboard.Weather.Provider. Never a raw provider value.
    attribute :severity, :string do
      allow_nil? false
      public? true
    end

    # Provider-specific numeric rank; lower is more significant.
    attribute :priority, :integer do
      public? true
    end

    attribute :category, :string do
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :body, :string do
      public? true
    end

    attribute :color, :string do
      public? true
    end

    attribute :emergency, :boolean do
      public? true
    end

    attribute :begins_at, :utc_datetime do
      public? true
    end

    attribute :expires_at, :utc_datetime do
      public? true
    end

    attribute :issued_at, :utc_datetime do
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
