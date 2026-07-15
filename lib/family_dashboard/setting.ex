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
      :daily_refresh_minutes,
      :sync_max_attempts,
      :alerts_min_severity,
      :alerts_hidden_categories,
      :alerts_show_body,
      :news_refresh_minutes,
      :news_retention_hours,
      :news_ticker_chars_per_second
    ]

    defaults [:read, create: @writable]

    # Non-atomic because the time_zone validation resolves the zone in Elixir
    # (can't be expressed as a DB expression). Fine for a rarely-edited singleton.
    update :update do
      primary? true
      require_atomic? false
      accept @writable
    end

    # System-set weather fetch status (not user-editable in the admin forms).
    update :record_weather_status do
      require_atomic? false
      accept [:weather_last_error, :weather_last_attempted_at, :daily_last_attempted_at]
    end

    # System-set news fetch-attempt timestamp (not user-editable). Heartbeat
    # gates the next refresh on this, exactly like weather_last_attempted_at —
    # a single Oban worker refreshes every enabled feed together, so there's
    # one global cadence rather than a per-feed one.
    update :record_news_attempt do
      require_atomic? false
      accept [:news_last_attempted_at]
    end
  end

  validations do
    validate {FamilyDashboard.Validations.ValidTimeZone, []}
    validate {FamilyDashboard.Validations.ValidSeverity, []}
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

    # System-set status of the most recent weather refresh (surfaced on the
    # dashboard and in the admin so a blank weather panel is self-explanatory).
    attribute :weather_last_error, :string do
      public? true
    end

    attribute :weather_last_attempted_at, :utc_datetime do
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
      default 15
      constraints min: 1
    end

    # The 7-day forecast changes slowly and its endpoint is flaky, so it refreshes
    # on its own, less-frequent schedule via a separate Oban job.
    attribute :daily_refresh_minutes, :integer do
      public? true
      allow_nil? false
      default 60
      constraints min: 1
    end

    attribute :daily_last_attempted_at, :utc_datetime do
      public? true
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

    # Minimum severity (of "extreme" | "severe" | "moderate" | "minor" — see
    # FamilyDashboard.Weather.Provider) an alert must meet to render on the
    # dashboard's Weather Alerts card. Validated by
    # FamilyDashboard.Validations.ValidSeverity.
    attribute :alerts_min_severity, :string do
      public? true
      allow_nil? false
      default "moderate"
    end

    # Comma-delimited alert `category` tokens (e.g. "small craft advisory,air
    # quality") to hide regardless of severity. Empty string means show every
    # category. A plain delimited string (not an Ash array type) so it stays
    # consistent with every other scalar setting on this resource and is
    # guaranteed-editable as a plain text field in ash_admin. Parsed in
    # DashboardLive.
    attribute :alerts_hidden_categories, :string do
      public? true
      allow_nil? false
      default ""
      constraints allow_empty?: true
    end

    # Whether the Weather Alerts card shows each alert's body text beneath its
    # name, or just the compact name + active-until time.
    attribute :alerts_show_body, :boolean do
      public? true
      allow_nil? false
      default false
    end

    # Scheduling knob for the news ticker's Oban refresh, mirroring
    # weather_refresh_minutes. A single worker refreshes every enabled
    # NewsFeed on this cadence (see FamilyDashboard.News.refresh_all/1).
    attribute :news_refresh_minutes, :integer do
      public? true
      allow_nil? false
      default 15
      constraints min: 1
    end

    # How long a NewsItem is kept once its effective_time (published_at,
    # falling back to inserted_at) falls outside this window — see
    # FamilyDashboard.NewsReaper.
    attribute :news_retention_hours, :integer do
      public? true
      allow_nil? false
      default 24
      constraints min: 1
    end

    # Reading pace for the ticker's marquee, in characters per second of
    # animation — see marquee_duration/2 in DashboardLive. Higher scrolls
    # faster.
    attribute :news_ticker_chars_per_second, :integer do
      public? true
      allow_nil? false
      default 14
      constraints min: 1
    end

    # Set on every news refresh attempt (regardless of per-feed success or
    # failure) by FamilyDashboard.News.refresh_all/1. Not in @writable —
    # system-set only.
    attribute :news_last_attempted_at, :utc_datetime do
      public? true
    end

    timestamps()
  end
end
