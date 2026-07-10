defmodule FamilyDashboard.Setting do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  sqlite do
    table "settings"
    repo FamilyDashboard.Repo
  end

  # Fixed one-minute heartbeat. The `:tick` action reads this row live and
  # enqueues only the sync work that is currently due (see FamilyDashboard.Heartbeat).
  oban do
    scheduled_actions do
      schedule :heartbeat, "* * * * *" do
        action :tick
        queue :default
        worker_module_name FamilyDashboard.Workers.HeartbeatScheduler
      end
    end
  end

  actions do
    # Settings is a singleton; :current returns the single row (or nil if unseeded).
    read :current do
      get? true
      prepare build(sort: [inserted_at: :asc], limit: 1)
    end

    # Driven by the scheduled action above; enqueues due sync jobs.
    action :tick, :atom do
      run fn _input, _context ->
        FamilyDashboard.Heartbeat.run()
        {:ok, :ticked}
      end
    end

    @writable [
      :latitude,
      :longitude,
      :city_label,
      :units,
      :greeting,
      :time_zone,
      :calendar_sync_minutes,
      :weather_refresh_minutes,
      :sync_max_attempts
    ]

    defaults [:read, create: @writable]

    # Non-atomic because the time_zone validation resolves the zone in Elixir
    # (can't be expressed as a DB expression). Fine for a rarely-edited singleton.
    update :update do
      primary? true
      require_atomic? false
      accept @writable
    end
  end

  validations do
    validate {FamilyDashboard.Validations.ValidTimeZone, []}
  end

  attributes do
    uuid_primary_key :id

    attribute :latitude, :float do
      public? true
    end

    attribute :longitude, :float do
      public? true
    end

    attribute :city_label, :string do
      public? true
    end

    attribute :units, :string do
      public? true
    end

    # IANA name (e.g. "America/Chicago"); the dashboard's "today" is computed here.
    attribute :time_zone, :string do
      public? true
      allow_nil? false
      default "America/Chicago"
    end

    # Scheduling knobs — edited in the settings panel, read live by the heartbeat.
    attribute :calendar_sync_minutes, :integer do
      public? true
      allow_nil? false
      default 15
      constraints min: 1
    end

    attribute :weather_refresh_minutes, :integer do
      public? true
      allow_nil? false
      default 30
      constraints min: 1
    end

    attribute :sync_max_attempts, :integer do
      public? true
      allow_nil? false
      default 3
      constraints min: 1
    end

    attribute :greeting, :string do
      public? true
    end

    timestamps()
  end
end
