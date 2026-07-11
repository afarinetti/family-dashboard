defmodule FamilyDashboard.Calendar do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "calendars"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :name,
        :ical_url,
        :color,
        :active,
        :last_synced_at,
        :last_attempted_at,
        :last_error
      ],
      update: [
        :name,
        :ical_url,
        :color,
        :active,
        :last_synced_at,
        :last_attempted_at,
        :last_error
      ]
    ]

    # Used by FamilyDashboard.Backup to restore calendars from a JSON export:
    # updates an existing row by id (leaving its sync-status fields alone —
    # Backup resets those separately, in its own follow-up call) or inserts a
    # new one. Never touches a calendar that isn't present in the backup.
    create :upsert do
      upsert? true
      upsert_identity :id
      upsert_fields [:name, :ical_url, :color, :active]
      accept [:id, :name, :ical_url, :color, :active]
    end
  end

  attributes do
    uuid_primary_key :id do
      writable? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :ical_url, :string do
      allow_nil? false
      public? true
    end

    attribute :color, :string do
      public? true
    end

    attribute :active, :boolean do
      public? true
      allow_nil? false
      default true
    end

    attribute :last_synced_at, :utc_datetime do
      public? true
    end

    # Set on every sync attempt (success or failure); the heartbeat gates on this
    # so a persistently-failing feed is retried on its interval, not every minute.
    attribute :last_attempted_at, :utc_datetime do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    timestamps()
  end

  identities do
    identity :id, [:id]
  end
end
