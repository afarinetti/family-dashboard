defmodule FamilyDashboard.NewsItem do
  @moduledoc """
  One persisted headline from a `FamilyDashboard.NewsFeed`. Deduplicated per
  feed via the `feed_guid` identity on `[news_feed_id, guid]` — `guid` is
  never nil at write time; `FamilyDashboard.News` falls back to the item's
  `url` when a feed doesn't supply one, so a single non-null identity is
  enough (no separate "dedup by url" path is needed).

  `published_at` is not always present, so both the dashboard's newest-first
  ordering and `FamilyDashboard.NewsReaper`'s retention window use
  `effective_time/1` rather than `published_at` directly.
  """
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer,
    primary_read_warning?: false

  sqlite do
    table "news_items"
    repo FamilyDashboard.Repo

    references do
      # Deleting a NewsFeed (e.g. from ash_admin) should take its items with
      # it, rather than failing on the FK constraint or leaving orphans.
      reference :news_feed, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
      prepare build(load: [:news_feed])
    end

    defaults [:destroy]

    create :create do
      primary? true
      upsert? true
      upsert_identity :feed_guid
      upsert_fields [:title, :url, :published_at]
      accept [:news_feed_id, :guid, :title, :url, :published_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :guid, :string do
      allow_nil? false
      public? true
    end

    attribute :published_at, :utc_datetime do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :news_feed, FamilyDashboard.NewsFeed do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :feed_guid, [:news_feed_id, :guid]
  end

  @doc """
  The timestamp used for sorting and retention: `published_at`, falling back
  to `inserted_at` (fetch time) when the feed didn't supply one.
  """
  @spec effective_time(map()) :: DateTime.t()
  def effective_time(%{published_at: nil, inserted_at: inserted_at}), do: inserted_at
  def effective_time(%{published_at: published_at}), do: published_at
end
