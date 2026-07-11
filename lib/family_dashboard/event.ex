defmodule FamilyDashboard.Event do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "events"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Upserts on the per-occurrence identity so re-pulled occurrences update
    # in place (title/time/location changes) instead of creating duplicates.
    # Sync.replace_window_events/4 prunes anything no longer returned by the
    # feed, so this stays "self-cleaning" for ended/removed occurrences too.
    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_occurrence
      upsert_fields [:title, :ends_at, :all_day, :location]
      accept [:title, :starts_at, :ends_at, :all_day, :location, :uid, :calendar_id]
    end

    update :update do
      primary? true
      accept [:title, :starts_at, :ends_at, :all_day, :location, :uid]
    end

    # Concrete occurrences whose start falls within [from, to], ordered for display.
    read :in_window do
      argument :from, :utc_datetime, allow_nil?: false
      argument :to, :utc_datetime, allow_nil?: false

      filter expr(starts_at >= ^arg(:from) and starts_at <= ^arg(:to))
      prepare build(sort: [starts_at: :asc], load: [:calendar])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :starts_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :ends_at, :utc_datetime do
      public? true
    end

    attribute :all_day, :boolean do
      public? true
    end

    attribute :location, :string do
      public? true
    end

    attribute :uid, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :calendar, FamilyDashboard.Calendar do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    # A recurring event shares one uid across occurrences; the start disambiguates.
    identity :unique_occurrence, [:calendar_id, :uid, :starts_at]
  end
end
