defmodule FamilyDashboard.NewsFeed do
  @moduledoc """
  An operator-configured RSS/Atom feed source for the dashboard's news ticker.
  Managed via ash_admin (see `FamilyDashboard.Dashboard`'s `admin do show? true
  end`), the same way `FamilyDashboard.Calendar` is.

  `last_fetched_at`/`last_error` are system-set observability fields (like
  `Setting`'s weather status fields) — they do not gate anything; the global
  refresh cadence is gated on `Setting.news_last_attempted_at` instead, since
  one Oban worker refreshes every enabled feed together.
  """
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "news_feeds"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:url, :label, :enabled, :last_fetched_at, :last_error],
      update: [:url, :label, :enabled, :last_fetched_at, :last_error]
    ]

    # Used by FamilyDashboard.Backup to restore news feeds from a JSON export:
    # updates an existing row by id (leaving last_fetched_at/last_error alone —
    # Backup resets those separately) or inserts a new one. Mirrors
    # FamilyDashboard.Calendar's :upsert action.
    create :upsert do
      upsert? true
      upsert_identity :id
      upsert_fields [:url, :label, :enabled]
      accept [:id, :url, :label, :enabled]
    end
  end

  attributes do
    uuid_primary_key :id do
      writable? true
    end

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      public? true
      allow_nil? false
      default true
    end

    attribute :last_fetched_at, :utc_datetime do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :items, FamilyDashboard.NewsItem do
      destination_attribute :news_feed_id
    end
  end

  identities do
    identity :id, [:id]
  end
end
