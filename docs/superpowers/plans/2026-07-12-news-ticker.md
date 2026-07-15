# Bottom News Ticker (Chiron) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-width, continuously-scrolling news chiron to the bottom of the wall dashboard, fed by operator-configured RSS/Atom feeds.

**Architecture:** A `NewsFeed` Ash resource (operator-managed via `ash_admin`, like `Calendar`) and a `NewsItem` resource (persisted headlines, upserted on `[news_feed_id, guid]`) back a fetch pipeline (`FamilyDashboard.News`, using `Req` + the `fiet` library to parse RSS 2.0/Atom) that runs as an Oban worker on the existing minute-cadence `Heartbeat`, gated by a new `news_refresh_minutes` setting. Each feed is fetched independently and best-effort: a failing feed keeps its existing items (no carry-forward removal, no pruning) and just records `last_error`. A daily `NewsReaper` cron deletes items past a retention window while always protecting the newest item per feed. `DashboardLive` renders the merged, newest-first items as a seamless CSS marquee pinned to the bottom of the screen, isolated from the existing 30-second clock tick via `phx-update="ignore"`.

**Tech Stack:** Elixir ~1.17, Phoenix 1.8.9, Phoenix LiveView ~1.2.0, Ash 3.29.3, ash_sqlite, Oban 2.23.0 (SQLite engine), Req (HTTP), `fiet` (RSS/Atom parsing, wraps `saxy`), Tailwind v4 + daisyUI.

## Global Constraints

- `mix test` is aliased to `["ash.setup --quiet", "test"]` (`mix.exs`) — it auto-migrates and re-seeds the test DB. Never hand-run `mix ecto.migrate` for tests; just run `mix test`.
- After any Ash attribute/relationship change, run `mix ash.codegen <name>` (generates a migration + updates `priv/resource_snapshots/`) then `mix ash.migrate` before running tests that touch the changed resource.
- Ash resource files follow the spark formatter's section order configured in `config/config.exs`: `admin, resource, code_interface, actions, policies, pub_sub, preparations, changes, validations, multitenancy, attributes, relationships, calculations, aggregates, identities`.
- Commit messages are plain imperative sentences, no prefix (e.g. "Add the NewsFeed and NewsItem resources").
- HEEx auto-escapes interpolated text — feed-sourced titles/labels must never be passed through `raw/1`.
- Tailwind v4's content scanner (`assets/css/app.css`'s `@source` directives) only generates CSS for class-looking substrings that appear **literally** in a scanned file — the `animate-marquee` utility name must appear verbatim in `dashboard_live.ex`, matching the existing `animate-blink` precedent.
- Test conventions in this codebase: pure/no-DB logic (parsing, formatting) uses `ExUnit.Case, async: true` (see `weather/xweather_test.exs`); anything touching the DB uses `FamilyDashboard.DataCase`; LiveView tests use `FamilyDashboardWeb.ConnCase` + `import Phoenix.LiveViewTest`; Oban assertions need `use Oban.Testing, repo: FamilyDashboard.Repo`.
- `Req.get/1` is stubbed in tests by merging a `plug: fn conn -> ... end` option into the request — no global `Req.Test.stub` setup needed (see `sync_test.exs`, `xweather_test.exs`).
- The `/ops` hub is HTTP Basic Auth-gated in tests: `conn |> authed() |> live(~p"/ops")` (see `ops_live_test.exs`'s `authed/1` helper).
- **Two additions in this plan sit outside the approved design spec's file list, both required to make the feature actually work / be verifiable, called out explicitly rather than left implicit:** a `news_last_attempted_at` field on `Setting` (Heartbeat needs a gating timestamp exactly like the existing `weather_last_attempted_at`) and a "Refresh news now" button on the `/ops` hub (the spec's own manual verification step requires it, mirroring the existing weather/calendar buttons).
- Unlike `Sync.sync_calendar/2` (which deletes-and-reprunes on every sync), **news refresh never prunes**. Carry-forward-on-failure depends entirely on this: a feed's existing items are only ever removed by `NewsReaper`, on its own schedule.

---

### Task 1: `NewsFeed` and `NewsItem` resources

**Files:**
- Create: `lib/family_dashboard/news_feed.ex`
- Create: `lib/family_dashboard/news_item.ex`
- Modify: `lib/family_dashboard/dashboard.ex`
- Test: `test/family_dashboard/news_feed_test.exs` (new)
- Test: `test/family_dashboard/news_item_test.exs` (new)
- Generated: `priv/repo/migrations/<timestamp>_add_news_feeds_and_items.exs`, `priv/resource_snapshots/repo/news_feeds/*`, `priv/resource_snapshots/repo/news_items/*`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `FamilyDashboard.Dashboard.list_news_feeds/0,!/0`, `get_news_feed/1,!/1`, `create_news_feed/1,!/1`, `update_news_feed/2,!/2`, `destroy_news_feed/1,!/1`; `create_news_item/1,!/1`, `list_news_items/0,!/0` (items always loaded with `:news_feed`). `FamilyDashboard.NewsItem.effective_time/1` — `published_at`, falling back to `inserted_at`. Every later task consumes these.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/news_feed_test.exs`:

```elixir
defmodule FamilyDashboard.NewsFeedTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  test "creates a feed with defaults" do
    assert {:ok, feed} =
             Dashboard.create_news_feed(%{url: "https://example.com/rss.xml", label: "Example"})

    assert feed.url == "https://example.com/rss.xml"
    assert feed.label == "Example"
    assert feed.enabled == true
    assert feed.last_fetched_at == nil
    assert feed.last_error == nil
  end

  test "requires url and label" do
    assert {:error, _} = Dashboard.create_news_feed(%{})
  end

  test "can be disabled and updated" do
    feed = Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})

    assert {:ok, updated} = Dashboard.update_news_feed(feed, %{enabled: false})
    assert updated.enabled == false
  end

  test "has_many :items loads its news items" do
    feed = Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "item-1",
      title: "Headline",
      url: "https://example.com/a"
    })

    loaded = Ash.load!(feed, :items)
    assert length(loaded.items) == 1
  end
end
```

Create `test/family_dashboard/news_item_test.exs`:

```elixir
defmodule FamilyDashboard.NewsItemTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_feed do
    Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})
  end

  test "creates an item attached to a feed" do
    feed = create_feed()

    assert {:ok, item} =
             Dashboard.create_news_item(%{
               news_feed_id: feed.id,
               guid: "item-1",
               title: "Headline",
               url: "https://example.com/a",
               published_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert item.news_feed_id == feed.id
    assert item.title == "Headline"
  end

  test "requires title, url, and guid" do
    feed = create_feed()
    assert {:error, _} = Dashboard.create_news_item(%{news_feed_id: feed.id})
  end

  test "upserts on [news_feed_id, guid] instead of creating a duplicate" do
    feed = create_feed()

    first =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "item-1",
        title: "Original headline",
        url: "https://example.com/a"
      })

    second =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "item-1",
        title: "Updated headline",
        url: "https://example.com/a-updated"
      })

    assert second.id == first.id
    assert second.title == "Updated headline"
    assert FamilyDashboard.NewsItem |> Ash.read!() |> length() == 1
  end

  test "the same guid on two different feeds does not collide" do
    feed_a = create_feed()
    feed_b = Dashboard.create_news_feed!(%{url: "https://example.com/other.xml", label: "Other"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed_a.id,
      guid: "shared-guid",
      title: "From A",
      url: "https://example.com/a"
    })

    Dashboard.create_news_item!(%{
      news_feed_id: feed_b.id,
      guid: "shared-guid",
      title: "From B",
      url: "https://example.com/b"
    })

    assert FamilyDashboard.NewsItem |> Ash.read!() |> length() == 2
  end

  describe "effective_time/1" do
    test "uses published_at when present" do
      feed = create_feed()

      published =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      item =
        Dashboard.create_news_item!(%{
          news_feed_id: feed.id,
          guid: "item-1",
          title: "Headline",
          url: "https://example.com/a",
          published_at: published
        })

      assert FamilyDashboard.NewsItem.effective_time(item) == published
    end

    test "falls back to inserted_at when published_at is nil" do
      feed = create_feed()

      item =
        Dashboard.create_news_item!(%{
          news_feed_id: feed.id,
          guid: "item-1",
          title: "Headline",
          url: "https://example.com/a"
        })

      assert FamilyDashboard.NewsItem.effective_time(item) == item.inserted_at
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/news_feed_test.exs test/family_dashboard/news_item_test.exs`
Expected: FAIL — `FamilyDashboard.NewsFeed`/`FamilyDashboard.NewsItem` don't exist and `Dashboard.create_news_feed/1` is undefined.

- [ ] **Step 3: Create the `NewsFeed` resource**

Create `lib/family_dashboard/news_feed.ex`:

```elixir
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
  end

  attributes do
    uuid_primary_key :id

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
end
```

- [ ] **Step 4: Create the `NewsItem` resource**

Create `lib/family_dashboard/news_item.ex`:

```elixir
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
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "news_items"
    repo FamilyDashboard.Repo
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
  @spec effective_time(t()) :: DateTime.t()
  def effective_time(%__MODULE__{published_at: nil, inserted_at: inserted_at}), do: inserted_at
  def effective_time(%__MODULE__{published_at: published_at}), do: published_at
end
```

- [ ] **Step 5: Register both resources in the domain**

In `lib/family_dashboard/dashboard.ex`, add these two `resource` blocks inside `resources do ... end`, immediately after the `FamilyDashboard.Setting` block:

```elixir
    resource FamilyDashboard.NewsFeed do
      define :list_news_feeds, action: :read
      define :get_news_feed, action: :read, get_by: [:id]
      define :create_news_feed, action: :create
      define :update_news_feed, action: :update
      define :destroy_news_feed, action: :destroy
    end

    resource FamilyDashboard.NewsItem do
      define :create_news_item, action: :create
      define :list_news_items, action: :read
    end
```

- [ ] **Step 6: Generate and run the migration**

Run: `mix ash.codegen add_news_feeds_and_items`
Expected: a new file under `priv/repo/migrations/` creating `news_feeds` and `news_items` tables, the latter with a `news_feed_id` foreign key. Read the generated migration before applying it — confirm it does exactly this and nothing else.

Run: `mix ash.migrate`
Expected: migration applies with no errors.

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/family_dashboard/news_feed_test.exs test/family_dashboard/news_item_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/family_dashboard/news_feed.ex lib/family_dashboard/news_item.ex lib/family_dashboard/dashboard.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/news_feed_test.exs test/family_dashboard/news_item_test.exs
git commit -m "Add the NewsFeed and NewsItem resources"
```

---

### Task 2: News scheduling settings on `Setting`

**Files:**
- Modify: `lib/family_dashboard/setting.ex`
- Test: `test/family_dashboard/setting_test.exs` (modify)
- Generated: `priv/repo/migrations/<timestamp>_add_news_settings.exs`, updated `priv/resource_snapshots/repo/settings/*`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Setting.news_refresh_minutes` (integer, default 15, operator-writable), `Setting.news_retention_hours` (integer, default 24, operator-writable), `Setting.news_last_attempted_at` (utc_datetime, system-set only). `Dashboard.record_news_attempt/2,!/2` (accepts `:news_last_attempted_at`). Task 4 (`Heartbeat`/`News`) and Task 5 (`NewsReaper`) both consume these.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/setting_test.exs`, add this `describe` block immediately after the existing `describe "alert filter settings"` block (before the module's closing `end`):

```elixir
  describe "news scheduling settings" do
    test "default to a 15 minute refresh and 24 hour retention" do
      assert setting().news_refresh_minutes == 15
      assert setting().news_retention_hours == 24
      assert setting().news_last_attempted_at == nil
    end

    test "news_refresh_minutes and news_retention_hours are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 news_refresh_minutes: 30,
                 news_retention_hours: 12
               })

      assert updated.news_refresh_minutes == 30
      assert updated.news_retention_hours == 12
    end

    test "record_news_attempt stamps news_last_attempted_at" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, updated} =
               Dashboard.record_news_attempt(setting(), %{news_last_attempted_at: now})

      assert updated.news_last_attempted_at == now
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/setting_test.exs`
Expected: FAIL — `news_refresh_minutes`/`news_retention_hours`/`news_last_attempted_at` don't exist and `Dashboard.record_news_attempt/2` is undefined.

- [ ] **Step 3: Add the attributes and action**

In `lib/family_dashboard/setting.ex`, replace the `@writable` list:

```elixir
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
      :news_retention_hours
    ]
```

In the same file, add this action immediately after the existing `update :record_weather_status do ... end` block (before the closing `end` of `actions do ... end`):

```elixir
    # System-set news fetch-attempt timestamp (not user-editable). Heartbeat
    # gates the next refresh on this, exactly like weather_last_attempted_at —
    # a single Oban worker refreshes every enabled feed together, so there's
    # one global cadence rather than a per-feed one.
    update :record_news_attempt do
      require_atomic? false
      accept [:news_last_attempted_at]
    end
```

In the same file, add these three attributes immediately after the existing `alerts_show_body` attribute (before `timestamps()`):

```elixir
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

    # Set on every news refresh attempt (regardless of per-feed success or
    # failure) by FamilyDashboard.News.refresh_all/1. Not in @writable —
    # system-set only.
    attribute :news_last_attempted_at, :utc_datetime do
      public? true
    end
```

- [ ] **Step 4: Register the code interface**

In `lib/family_dashboard/dashboard.ex`, add this line inside the `resource FamilyDashboard.Setting do ... end` block, immediately after `define :record_weather_status, action: :record_weather_status`:

```elixir
      define :record_news_attempt, action: :record_news_attempt
```

- [ ] **Step 5: Generate and run the migration**

Run: `mix ash.codegen add_news_settings`
Expected: a new file under `priv/repo/migrations/` adding `news_refresh_minutes`, `news_retention_hours`, `news_last_attempted_at` columns to `settings`. Read the generated migration before applying it.

Run: `mix ash.migrate`
Expected: migration applies with no errors.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/family_dashboard/setting_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/family_dashboard/setting.ex lib/family_dashboard/dashboard.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/setting_test.exs
git commit -m "Add operator-configurable news refresh/retention settings"
```

---

### Task 3: `FamilyDashboard.News.fetch_items/2` — fetch and parse one feed

**Files:**
- Modify: `mix.exs`
- Create: `lib/family_dashboard/news.ex`
- Test: `test/family_dashboard/news_test.exs` (new)

**Interfaces:**
- Consumes: nothing from other tasks (pure — no DB, no Ash).
- Produces: `FamilyDashboard.News.fetch_items(url, opts \\ [])` returning `{:ok, [%{title:, url:, guid:, published_at:}]} | {:error, term()}`. Task 4 consumes this directly.

- [ ] **Step 1: Add the `fiet` dependency**

In `mix.exs`, add this line to the `deps` list, immediately after `{:ical, "~> 3.0"},`:

```elixir
      {:fiet, "~> 0.3.0"},
```

Run: `mix deps.get`
Expected: fetches `fiet` and its own dependency `saxy` (a pure-Elixir XML SAX parser — no NIFs).

- [ ] **Step 2: Write the failing tests**

Create `test/family_dashboard/news_test.exs`:

```elixir
defmodule FamilyDashboard.NewsTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.News

  defp rss(items_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <link>https://example.com</link>
        <description>Example</description>
        #{items_xml}
      </channel>
    </rss>
    """
  end

  defp atom(entries_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Example Feed</title>
      #{entries_xml}
    </feed>
    """
  end

  describe "fetch_items/2 — RSS 2.0" do
    test "parses title, link, guid, and an RFC-822 pubDate" do
      xml =
        rss("""
        <item>
          <title>Council approves new park</title>
          <link>https://example.com/park</link>
          <guid>abc-123</guid>
          <pubDate>Wed, 02 Oct 2024 15:00:00 GMT</pubDate>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Council approves new park"
      assert item.url == "https://example.com/park"
      assert item.guid == "abc-123"
      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end

    test "parses an RFC-822 pubDate with a numeric UTC offset" do
      xml =
        rss("""
        <item>
          <title>Local edition</title>
          <link>https://example.com/local</link>
          <guid>local-1</guid>
          <pubDate>Wed, 02 Oct 2024 11:00:00 -0400</pubDate>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end

    test "decodes an HTML entity in a plain title" do
      xml =
        rss("""
        <item>
          <title>Storm &amp; Flood Watch</title>
          <link>https://example.com/storm</link>
          <guid>storm-1</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Storm & Flood Watch"
    end

    test "passes through a CDATA-wrapped title without double-escaping it" do
      # Per the XML spec, CDATA content is literal — entities are NOT decoded
      # inside it. Feeds that use CDATA embed already-raw characters directly
      # (unlike the plain-entity case above), so this must come out unchanged.
      xml =
        rss("""
        <item>
          <title><![CDATA[Storm & Flood Watch]]></title>
          <link>https://example.com/storm-cdata</link>
          <guid>storm-2</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Storm & Flood Watch"
    end

    test "falls back to the url as guid when the feed has none" do
      xml =
        rss("""
        <item>
          <title>No guid here</title>
          <link>https://example.com/no-guid</link>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.guid == "https://example.com/no-guid"
    end

    test "published_at is nil when pubDate is missing" do
      xml =
        rss("""
        <item>
          <title>No date</title>
          <link>https://example.com/no-date</link>
          <guid>no-date-1</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.published_at == nil
    end

    test "drops an item with no title or no link" do
      xml =
        rss("""
        <item>
          <link>https://example.com/no-title</link>
          <guid>x</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, []} = News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end
  end

  describe "fetch_items/2 — Atom" do
    test "parses title, link, id, and an ISO-8601 published timestamp" do
      xml =
        atom("""
        <entry>
          <title>Markets rise on jobs data</title>
          <link rel="alternate" href="https://example.com/markets"/>
          <id>urn:uuid:abc-123</id>
          <published>2024-10-02T15:00:00Z</published>
        </entry>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/atom.xml", plug: plug)

      assert item.title == "Markets rise on jobs data"
      assert item.url == "https://example.com/markets"
      assert item.guid == "urn:uuid:abc-123"
      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end
  end

  describe "fetch_items/2 — transport and parse errors" do
    test "returns an error tuple on a non-200 response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, {:http_status, 500}} =
               News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end

    test "returns an error tuple on malformed XML" do
      plug = fn conn -> Req.Test.text(conn, "not xml at all") end

      assert {:error, _reason} = News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/family_dashboard/news_test.exs`
Expected: FAIL — `FamilyDashboard.News` doesn't exist.

- [ ] **Step 4: Implement `News.fetch_items/2`**

Create `lib/family_dashboard/news.ex`:

```elixir
defmodule FamilyDashboard.News do
  @moduledoc """
  Fetches and normalizes RSS/Atom feeds into plain item maps — the same
  "normalize to plain maps" seam `FamilyDashboard.Weather.Provider` adapters
  use, so persistence stays parser-agnostic. XML parsing is wrapped behind
  this module (via the `fiet` dependency) rather than called directly from
  anywhere else, so swapping the underlying library later never touches a
  caller.
  """

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @rfc822 ~r/(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*(GMT|UT|Z|[+-]\d{4})?/

  @doc """
  Fetches and parses one feed URL. Returns `{:ok, [item]}` where each item is
  `%{title:, url:, guid:, published_at:}`, or `{:error, reason}` on an HTTP or
  parse failure. Items missing a title or url are dropped — a headline with
  nowhere to link is useless on the ticker. `opts` is passed through to
  `Req.get/1` (e.g. `plug:` in tests, mirroring `Weather.Xweather`'s `get/3`).
  """
  @spec fetch_items(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_items(url, opts \\ []) do
    request = Keyword.merge([url: url, retry: false, receive_timeout: 10_000], opts)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(body) when is_binary(body) do
    case Fiet.parse(body) do
      {:ok, %Fiet.Feed{items: items}} ->
        {:ok, items |> Enum.map(&normalize_item/1) |> Enum.filter(& &1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_item(%Fiet.Item{title: title, link: url}) when is_nil(title) or is_nil(url) do
    nil
  end

  defp normalize_item(%Fiet.Item{} = item) do
    %{
      title: item.title,
      url: item.link,
      guid: item.id || item.link,
      published_at: parse_timestamp(item.published_at)
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      {:error, _} -> parse_rfc822(raw)
    end
  end

  defp parse_rfc822(raw) do
    case Regex.run(@rfc822, raw) do
      [_, day, mon, year, hour, min, sec, zone] ->
        with month when not is_nil(month) <- @months[mon],
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec)
               ) do
          naive |> apply_zone_offset(zone) |> DateTime.truncate(:second)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp apply_zone_offset(naive, zone) when zone in [nil, "", "GMT", "UT", "Z"] do
    DateTime.new!(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), "Etc/UTC")
  end

  defp apply_zone_offset(naive, <<sign, h1, h2, m1, m2>>) when sign in [?+, ?-] do
    offset = String.to_integer(<<h1, h2>>) * 3600 + String.to_integer(<<m1, m2>>) * 60
    offset = if sign == ?-, do: -offset, else: offset

    shifted = NaiveDateTime.add(naive, -offset, :second)
    DateTime.new!(NaiveDateTime.to_date(shifted), NaiveDateTime.to_time(shifted), "Etc/UTC")
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/family_dashboard/news_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock lib/family_dashboard/news.ex test/family_dashboard/news_test.exs
git commit -m "Add News.fetch_items/2, parsing RSS 2.0 and Atom feeds via fiet"
```

---

### Task 4: `News.refresh_all/1` persistence + `NewsRefresh` worker + Heartbeat + ops hub trigger

**Files:**
- Modify: `lib/family_dashboard/news.ex`
- Create: `lib/family_dashboard/workers/news_refresh.ex`
- Modify: `lib/family_dashboard/heartbeat.ex`
- Modify: `lib/family_dashboard_web/live/ops_live.ex`
- Test: `test/family_dashboard/news_test.exs` (modify)
- Test: `test/family_dashboard/heartbeat_test.exs` (modify)
- Test: `test/family_dashboard_web/live/ops_live_test.exs` (modify)

**Interfaces:**
- Consumes: `News.fetch_items/2` (Task 3), `Dashboard.create_news_item!/1`, `list_news_feeds!/0`, `update_news_feed!/2`, `record_news_attempt!/2` (Tasks 1–2).
- Produces: `FamilyDashboard.News.refresh_all(opts \\ [])` (`:ok`), `FamilyDashboard.Workers.NewsRefresh`, `Heartbeat.enqueue_news/1`. Task 5 does not depend on this; Task 6 (`DashboardLive`) reads the `NewsItem`s this produces.

- [ ] **Step 1: Write the failing tests for `News.refresh_all/1`**

In `test/family_dashboard/news_test.exs`, add `alias FamilyDashboard.Dashboard` to the top-of-file aliases and add this describe block at the end of the module (before the final `end`). Note this describe block needs the database, so it cannot share the file's `async: true` `ExUnit.Case` — add a second, `DataCase`-based test module in the same file:

```elixir
defmodule FamilyDashboard.News.RefreshAllTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, News}

  defp rss(items_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Feed</title>
        #{items_xml}
      </channel>
    </rss>
    """
  end

  test "fetches enabled feeds and persists their items" do
    feed = Dashboard.create_news_feed!(%{url: "https://feed.example/rss.xml", label: "Example"})

    xml =
      rss("""
      <item>
        <title>Council approves new park</title>
        <link>https://example.com/park</link>
        <guid>park-1</guid>
      </item>
      """)

    plug = fn conn -> Req.Test.text(conn, xml) end

    assert :ok = News.refresh_all(plug: plug)

    assert [item] = Dashboard.list_news_items!()
    assert item.title == "Council approves new park"
    assert item.news_feed_id == feed.id

    reloaded_feed = Dashboard.get_news_feed!(feed.id)
    assert reloaded_feed.last_fetched_at
    assert is_nil(reloaded_feed.last_error)
  end

  test "skips a disabled feed" do
    Dashboard.create_news_feed!(%{
      url: "https://feed.example/rss.xml",
      label: "Off",
      enabled: false
    })

    plug = fn conn -> Req.Test.text(conn, rss("")) end

    assert :ok = News.refresh_all(plug: plug)
    assert Dashboard.list_news_items!() == []
  end

  test "one feed failing does not block another, and keeps the failed feed's existing items" do
    good = Dashboard.create_news_feed!(%{url: "https://feed.example/good.xml", label: "Good"})
    bad = Dashboard.create_news_feed!(%{url: "https://feed.example/bad.xml", label: "Bad"})

    Dashboard.create_news_item!(%{
      news_feed_id: bad.id,
      guid: "old-item",
      title: "Old headline",
      url: "https://feed.example/old"
    })

    plug = fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/good.xml") ->
          Req.Test.text(
            conn,
            rss("""
            <item>
              <title>New headline</title>
              <link>https://feed.example/new</link>
              <guid>new-item</guid>
            </item>
            """)
          )

        String.ends_with?(conn.request_path, "/bad.xml") ->
          Plug.Conn.send_resp(conn, 500, "boom")
      end
    end

    assert :ok = News.refresh_all(plug: plug)

    titles = Dashboard.list_news_items!() |> Enum.map(& &1.title) |> Enum.sort()
    assert titles == ["New headline", "Old headline"]

    reloaded_bad = Dashboard.get_news_feed!(bad.id)
    assert reloaded_bad.last_error
  end

  test "broadcasts :news_updated after a refresh cycle" do
    Dashboard.create_news_feed!(%{url: "https://feed.example/rss.xml", label: "Example"})
    Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "news")

    plug = fn conn -> Req.Test.text(conn, rss("")) end
    assert :ok = News.refresh_all(plug: plug)

    assert_receive :news_updated
  end

  test "stamps news_last_attempted_at on the setting" do
    plug = fn conn -> Req.Test.text(conn, rss("")) end
    assert :ok = News.refresh_all(plug: plug)

    {:ok, setting} = Dashboard.current_setting()
    assert setting.news_last_attempted_at
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/news_test.exs`
Expected: FAIL — `News.refresh_all/1` is undefined.

- [ ] **Step 3: Implement `News.refresh_all/1`**

In `lib/family_dashboard/news.ex`, add `alias FamilyDashboard.Dashboard` immediately after the moduledoc, and add these functions at the end of the module (before the final `end`):

```elixir
  @doc """
  Fetches every enabled feed, each independently and best-effort, and upserts
  its items. A feed that fails to fetch keeps its existing items and records
  `last_error` — unlike `Sync.sync_calendar/2`, this never prunes; old items
  are removed only by `FamilyDashboard.NewsReaper`, on its own schedule.
  Always stamps `Setting.news_last_attempted_at`, regardless of per-feed
  outcome, so `Heartbeat` doesn't re-enqueue every minute.
  """
  @spec refresh_all(keyword()) :: :ok
  def refresh_all(opts \\ []) do
    record_attempt()

    Dashboard.list_news_feeds!()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(&refresh_feed(&1, opts))

    broadcast("news", :news_updated)
    :ok
  end

  defp refresh_feed(feed, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case fetch_items(feed.url, opts) do
      {:ok, items} ->
        Enum.each(items, fn item ->
          Dashboard.create_news_item!(Map.put(item, :news_feed_id, feed.id))
        end)

        Dashboard.update_news_feed!(feed, %{last_fetched_at: now, last_error: nil})

      {:error, reason} ->
        Dashboard.update_news_feed!(feed, %{last_error: inspect(reason)})
    end
  end

  defp record_attempt do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Dashboard.current_setting() do
      {:ok, %{} = setting} -> Dashboard.record_news_attempt!(setting, %{news_last_attempted_at: now})
      _ -> :ok
    end
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(FamilyDashboard.PubSub, topic, message)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/news_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit the persistence layer**

```bash
git add lib/family_dashboard/news.ex test/family_dashboard/news_test.exs
git commit -m "Persist fetched news items per-feed, best-effort, without pruning"
```

- [ ] **Step 6: Write the failing Heartbeat tests**

In `test/family_dashboard/heartbeat_test.exs`, add `NewsRefresh` to the existing `alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}` line (making it `alias FamilyDashboard.Workers.{CalendarSync, NewsRefresh, WeatherDailyRefresh, WeatherRefresh}`), then add this `describe` block immediately after the existing `describe "run/0 — daily forecast"` block:

```elixir
  describe "run/0 — news" do
    test "enqueues a news refresh when never attempted" do
      create_setting()

      assert :ok = Heartbeat.run()

      assert_enqueued(worker: NewsRefresh)
    end

    test "does not re-enqueue news within its interval" do
      create_setting(%{news_refresh_minutes: 15})
      recent = DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)

      {:ok, setting} = Dashboard.current_setting()
      Dashboard.record_news_attempt!(setting, %{news_last_attempted_at: recent})

      assert :ok = Heartbeat.run()

      refute_enqueued(worker: NewsRefresh)
    end
  end
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `mix test test/family_dashboard/heartbeat_test.exs`
Expected: FAIL — `FamilyDashboard.Workers.NewsRefresh` doesn't exist and `Heartbeat` doesn't enqueue news.

- [ ] **Step 8: Create the `NewsRefresh` worker**

Create `lib/family_dashboard/workers/news_refresh.ex`:

```elixir
defmodule FamilyDashboard.Workers.NewsRefresh do
  @moduledoc "Refreshes all enabled news feeds. Enqueued by the heartbeat when due."

  use Oban.Worker,
    queue: :default,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias FamilyDashboard.News

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    News.refresh_all()
  end
end
```

- [ ] **Step 9: Wire news into the Heartbeat**

Replace the full contents of `lib/family_dashboard/heartbeat.ex`:

```elixir
defmodule FamilyDashboard.Heartbeat do
  @moduledoc """
  The fixed-cadence tick (driven by an ash_oban scheduled action every minute).

  It reads the live `Setting` row and enqueues sync work only for what is
  actually *due* per the configured intervals — so the effective sync cadence
  and retry count are editable in the settings panel without a redeploy.

  `enqueue_weather/1`, `enqueue_daily/1`, `enqueue_news/1`, and
  `enqueue_calendar/3` are also used directly by the ops hub's manual "sync
  now" buttons (`force?: true`), which bypass each worker's Oban uniqueness
  window so a click always enqueues even if a job is already pending — see
  `FamilyDashboardWeb.OpsLive`.
  """

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, NewsRefresh, WeatherDailyRefresh, WeatherRefresh}

  # Fallbacks when the singleton Setting row hasn't been created yet.
  @default_calendar_minutes 15
  @default_weather_minutes 30
  @default_daily_minutes 60
  @default_news_minutes 15
  @default_max_attempts 3

  @spec run() :: :ok
  def run do
    setting = current_setting()
    now = DateTime.utc_now()

    enqueue_due_calendars(setting, now)
    enqueue_weather_if_due(setting, now)
    enqueue_daily_if_due(setting, now)
    enqueue_news_if_due(setting, now)
    :ok
  end

  @doc "Enqueues a weather refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_weather(boolean()) :: :ok
  def enqueue_weather(force? \\ false) do
    # max_attempts: 1 — weather is ephemeral; a failed fetch waits for the next
    # cycle rather than retrying in-cycle and burning the API quota.
    opts = [max_attempts: 1] ++ force_opts(force?)
    %{} |> WeatherRefresh.new(opts) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a daily-forecast refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_daily(boolean()) :: :ok
  def enqueue_daily(force? \\ false) do
    %{} |> WeatherDailyRefresh.new(force_opts(force?)) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a news refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_news(boolean()) :: :ok
  def enqueue_news(force? \\ false) do
    %{} |> NewsRefresh.new(force_opts(force?)) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a sync for one calendar. `force?: true` bypasses the worker's unique window."
  @spec enqueue_calendar(String.t(), pos_integer(), boolean()) :: :ok
  def enqueue_calendar(calendar_id, max_attempts, force? \\ false) do
    opts = [max_attempts: max_attempts] ++ force_opts(force?)
    %{calendar_id: calendar_id} |> CalendarSync.new(opts) |> Oban.insert()
    :ok
  end

  # `unique: false` on `.new/2` bypasses the worker's compile-time unique clause
  # for this single insert, so a manual click always enqueues instead of being
  # silently absorbed by a pending/executing job's uniqueness window.
  defp force_opts(true), do: [unique: false]
  defp force_opts(false), do: []

  defp enqueue_due_calendars(setting, now) do
    interval = minutes(setting, :calendar_sync_minutes, @default_calendar_minutes) * 60
    max_attempts = attempts(setting)

    Dashboard.list_calendars!()
    |> Enum.filter(& &1.active)
    |> Enum.filter(&calendar_due?(&1, now, interval))
    |> Enum.each(&enqueue_calendar(&1.id, max_attempts))
  end

  # No setting row yet — nothing to fetch or record status against.
  defp enqueue_weather_if_due(nil, _now), do: :ok

  defp enqueue_weather_if_due(setting, now) do
    interval = minutes(setting, :weather_refresh_minutes, @default_weather_minutes) * 60

    if attempt_due?(setting.weather_last_attempted_at, now, interval) do
      enqueue_weather()
    end
  end

  # The 7-day forecast refreshes on its own, less frequent schedule (the worker
  # itself retries the flaky endpoint).
  defp enqueue_daily_if_due(nil, _now), do: :ok

  defp enqueue_daily_if_due(setting, now) do
    interval = minutes(setting, :daily_refresh_minutes, @default_daily_minutes) * 60

    if attempt_due?(setting.daily_last_attempted_at, now, interval) do
      enqueue_daily()
    end
  end

  # One worker refreshes every enabled feed together, so there's a single
  # global cadence (news_last_attempted_at) rather than a per-feed one.
  defp enqueue_news_if_due(nil, _now), do: :ok

  defp enqueue_news_if_due(setting, now) do
    interval = minutes(setting, :news_refresh_minutes, @default_news_minutes) * 60

    if attempt_due?(setting.news_last_attempted_at, now, interval) do
      enqueue_news()
    end
  end

  # Gate on the last *attempt* (success or failure) so a broken feed is retried
  # on its interval, not re-enqueued every minute.
  defp calendar_due?(%{last_attempted_at: nil}, _now, _interval), do: true

  defp calendar_due?(%{last_attempted_at: last_attempted_at}, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  # Gate on the last *attempt*, not the last success — otherwise a
  # persistently-failing fetch is "due" every minute and hammers the source.
  # Shared by weather, the daily forecast, and news.
  defp attempt_due?(nil, _now, _interval), do: true

  defp attempt_due?(last_attempted_at, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  defp minutes(nil, _key, default), do: default
  defp minutes(setting, key, default), do: Map.get(setting, key) || default

  defp attempts(nil), do: @default_max_attempts
  defp attempts(setting), do: setting.sync_max_attempts || @default_max_attempts
end
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `mix test test/family_dashboard/heartbeat_test.exs`
Expected: PASS (including the pre-existing weather/daily tests, which now call the renamed `attempt_due?/3`).

- [ ] **Step 11: Commit**

```bash
git add lib/family_dashboard/workers/news_refresh.ex lib/family_dashboard/heartbeat.ex test/family_dashboard/heartbeat_test.exs
git commit -m "Enqueue news refreshes from the heartbeat when due"
```

- [ ] **Step 12: Write the failing ops hub tests**

In `test/family_dashboard_web/live/ops_live_test.exs`, add `NewsRefresh` to the existing `alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}` line, then add this test immediately after the existing `"lists a calendar with its sync status"` test:

```elixir
  test "lists a news feed with its fetch status", %{conn: conn} do
    Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Example Feed"
    assert html =~ "fetched never"
  end
```

Then, inside the `describe "manual triggers"` block, add this test immediately after the existing `"refresh_daily enqueues WeatherDailyRefresh"` test:

```elixir
    test "refresh_news enqueues NewsRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_news")

      assert_enqueued(worker: NewsRefresh)
    end
```

- [ ] **Step 13: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: FAIL — no "Example Feed" text rendered, and `refresh_news` isn't a handled event.

- [ ] **Step 14: Add the ops hub News section and manual trigger**

In `lib/family_dashboard_web/live/ops_live.ex`, replace the `mount/3` and the `handle_info`/`reload_status` block:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "news")
        reload_status(socket)
      else
        assign(socket, calendars: [], news_feeds: [], setting: nil)
      end

    socket =
      socket
      |> assign(confirming_restore: false, restore_error: nil)
      |> allow_upload(:backup, accept: ~w(.json), max_entries: 1)

    {:ok, socket}
  end

  @impl true
  def handle_info(:weather_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:events_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:news_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:reload_status, socket), do: {:noreply, reload_status(socket)}

  defp reload_status(socket) do
    assign(socket,
      calendars: Dashboard.list_calendars!(),
      news_feeds: Dashboard.list_news_feeds!(),
      setting: current_setting()
    )
  end
```

In the same file, insert a new "News" `<section>` immediately after the "Weather" section's closing `</section>` and before the "Calendars" section's opening `<section class="card bg-base-100 shadow-sm">`:

```elixir
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">News</h2>
              <.button phx-click="refresh_news">Refresh news now</.button>
            </div>
            <ul class="list">
              <li :for={feed <- @news_feeds} class="list-row">
                <div class="list-col-grow">
                  <div class="font-bold">
                    {feed.label}
                    <span class={[
                      "badge badge-sm",
                      feed.enabled && "badge-success",
                      !feed.enabled && "badge-ghost"
                    ]}>
                      {if feed.enabled, do: "enabled", else: "disabled"}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    fetched {relative_time(feed.last_fetched_at)}
                  </div>
                  <div :if={feed.last_error} class="text-sm text-error">{feed.last_error}</div>
                </div>
              </li>
            </ul>
          </div>
        </section>
```

In the same file, add this `handle_event` clause immediately after the existing `handle_event("refresh_weather", ...)` clause:

```elixir
  def handle_event("refresh_news", _params, socket) do
    Heartbeat.enqueue_news(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "News refresh queued.")}
  end
```

- [ ] **Step 15: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: PASS.

- [ ] **Step 16: Commit**

```bash
git add lib/family_dashboard_web/live/ops_live.ex test/family_dashboard_web/live/ops_live_test.exs
git commit -m "Add a News section and manual refresh trigger to the ops hub"
```

---

### Task 5: `NewsReaper` — retention with protect-newest-per-feed

**Files:**
- Create: `lib/family_dashboard/news_reaper.ex`
- Create: `lib/family_dashboard/workers/news_reap.ex`
- Modify: `config/config.exs`
- Test: `test/family_dashboard/news_reaper_test.exs` (new)

**Interfaces:**
- Consumes: `FamilyDashboard.NewsItem`, `FamilyDashboard.NewsItem.effective_time/1`, `Dashboard.current_setting/0` (Tasks 1–2).
- Produces: `FamilyDashboard.NewsReaper.reap/0` (`:ok`), `FamilyDashboard.Workers.NewsReap`. No other task depends on this.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/news_reaper_test.exs`:

```elixir
defmodule FamilyDashboard.NewsReaperTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, NewsReaper}

  defp create_feed(label \\ "Example") do
    Dashboard.create_news_feed!(%{url: "https://example.com/#{label}.xml", label: label})
  end

  defp create_item(feed, guid, published_at) do
    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: guid,
      title: "Item #{guid}",
      url: "https://example.com/#{guid}",
      published_at: published_at
    })
  end

  defp item_ids do
    FamilyDashboard.NewsItem |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes items older than the retention window" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old = create_item(feed, "old", DateTime.add(now, -48, :hour))
    recent = create_item(feed, "recent", DateTime.add(now, -1, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [recent.id]
    refute old.id in item_ids()
  end

  test "always protects the newest item per feed, even if it's older than the window" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    only_item = create_item(feed, "only", DateTime.add(now, -72, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [only_item.id]
  end

  test "protects the newest item independently per feed" do
    feed_a = create_feed("A")
    feed_b = create_feed("B")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    a_only = create_item(feed_a, "a-only", DateTime.add(now, -72, :hour))
    b_only = create_item(feed_b, "b-only", DateTime.add(now, -72, :hour))

    assert :ok = NewsReaper.reap()

    assert Enum.sort(item_ids()) == Enum.sort([a_only.id, b_only.id])
  end

  test "falls back to inserted_at for an item with no published_at" do
    feed = create_feed()

    recent_no_date =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "no-date",
        title: "No date",
        url: "https://example.com/no-date"
      })

    old_dated =
      create_item(
        feed,
        "old-dated",
        DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second)
      )

    assert :ok = NewsReaper.reap()

    assert item_ids() == [recent_no_date.id]
    refute old_dated.id in item_ids()
  end

  test "does nothing when there are no items" do
    assert :ok = NewsReaper.reap()
    assert item_ids() == []
  end

  test "respects a custom news_retention_hours setting" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{news_retention_hours: 1})

    within_new_window = create_item(feed, "within", DateTime.add(now, -30, :minute))
    outside_new_window = create_item(feed, "outside", DateTime.add(now, -2, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [within_new_window.id]
    refute outside_new_window.id in item_ids()
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/news_reaper_test.exs`
Expected: FAIL — `FamilyDashboard.NewsReaper` doesn't exist.

- [ ] **Step 3: Create the `NewsReaper`**

Create `lib/family_dashboard/news_reaper.ex`:

```elixir
defmodule FamilyDashboard.NewsReaper do
  @moduledoc """
  Deletes old `NewsItem` rows on a daily cron schedule (see
  `config/config.exs`), keyed off each item's `effective_time/1`
  (`published_at`, falling back to `inserted_at`). The newest item **per
  feed** is always protected, even if it's older than the retention window —
  mirrors `WeatherReaper`'s protect-latest rule, so a feed that goes quiet
  doesn't blank the ticker entirely.
  """

  require Ash.Query

  alias FamilyDashboard.{Dashboard, NewsItem}

  @default_retention_hours 24

  @doc "Deletes news items older than the configured retention window, protecting the newest per feed."
  @spec reap() :: :ok
  def reap do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_hours(), :hour)
    items = NewsItem |> Ash.read!()
    protected_ids = protected_ids(items)

    stale_ids =
      items
      |> Enum.reject(&(&1.id in protected_ids))
      |> Enum.filter(&(DateTime.compare(NewsItem.effective_time(&1), cutoff) == :lt))
      |> Enum.map(& &1.id)

    unless stale_ids == [] do
      Ash.bulk_destroy!(
        Ash.Query.filter(NewsItem, id in ^stale_ids),
        :destroy,
        %{},
        strategy: [:stream]
      )
    end

    :ok
  end

  defp protected_ids(items) do
    items
    |> Enum.group_by(& &1.news_feed_id)
    |> Enum.map(fn {_feed_id, feed_items} ->
      feed_items |> Enum.max_by(&NewsItem.effective_time/1, DateTime) |> Map.fetch!(:id)
    end)
  end

  defp retention_hours do
    case Dashboard.current_setting() do
      {:ok, %{news_retention_hours: hours}} when is_integer(hours) -> hours
      _ -> @default_retention_hours
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/news_reaper_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the `NewsReap` worker and register its daily cron**

Create `lib/family_dashboard/workers/news_reap.ex`:

```elixir
defmodule FamilyDashboard.Workers.NewsReap do
  @moduledoc """
  Reaps old news items on a daily cron schedule (see `config/config.exs`),
  alongside the weather reap and backup jobs. See `FamilyDashboard.NewsReaper`
  for the retention policy.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.NewsReaper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    NewsReaper.reap()
  end
end
```

In `config/config.exs`, replace the `crontab:` list inside the `config :family_dashboard, Oban, ...` block:

```elixir
     crontab: [
       {"0 3 * * *", FamilyDashboard.Workers.Backup},
       {"0 3 * * *", FamilyDashboard.Workers.WeatherReap},
       {"0 3 * * *", FamilyDashboard.Workers.NewsReap}
     ]
```

- [ ] **Step 6: Run the full test suite to confirm nothing else broke**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/family_dashboard/news_reaper.ex lib/family_dashboard/workers/news_reap.ex config/config.exs test/family_dashboard/news_reaper_test.exs
git commit -m "Add NewsReaper: daily retention with protect-newest-per-feed"
```

---

### Task 6: The chiron — dashboard layout, marquee render, and CSS animation

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex`
- Modify: `assets/css/app.css`
- Test: `test/family_dashboard_web/live/dashboard_live_test.exs` (modify)

**Interfaces:**
- Consumes: `Dashboard.list_news_items!/0` (Task 1, auto-loaded with `:news_feed`), `FamilyDashboard.NewsItem.effective_time/1` (Task 1), the `"news"` PubSub topic (Task 4).
- Produces: the rendered ticker. No other task depends on this (terminal task).

- [ ] **Step 1: Update the stale "no News" test and write the failing ticker tests**

In `test/family_dashboard_web/live/dashboard_live_test.exs`, remove this test (it predates the ticker and its premise — "there is no news on this dashboard" — is exactly what this feature reverses):

```elixir
  test "does not render a News card", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "News"
  end
```

Replace it with these three tests, in the same location:

```elixir
  test "shows no news ticker when there are no news items", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "animate-marquee"
  end

  test "renders a news item's source badge and headline in the ticker", %{conn: conn} do
    feed =
      Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "item-1",
      title: "Council approves new park",
      url: "https://example.com/park",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Example Feed"
    assert html =~ "Council approves new park"
    assert html =~ "animate-marquee"
  end

  test "orders ticker items newest first across feeds", %{conn: conn} do
    feed =
      Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example Feed"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "older",
      title: "Older headline",
      url: "https://example.com/older",
      published_at: DateTime.add(now, -3600, :second)
    })

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "newer",
      title: "Newer headline",
      url: "https://example.com/newer",
      published_at: now
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ ~r/Newer headline.*Older headline/s
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: FAIL — no `@news_items` assign exists yet, no ticker is rendered.

- [ ] **Step 3: Subscribe to the `"news"` topic and load items**

In `lib/family_dashboard_web/live/dashboard_live.ex`, replace `mount/3`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "news")
      Process.send_after(self(), :tick, @tick_ms)
    end

    socket = assign(socket, :agenda_days, @agenda_days)

    {:ok,
     socket
     |> assign_setting()
     |> assign_clock()
     |> load_weather()
     |> assign_active_alerts()
     |> load_events()
     |> load_news_items()}
  end
```

In the same file, add this `handle_info` clause immediately after the existing `handle_info(:weather_updated, socket)` clause:

```elixir
  def handle_info(:news_updated, socket), do: {:noreply, load_news_items(socket)}
```

In the same file, add this private function immediately after `load_events/1` (before the `event_date/2` functions):

```elixir
  defp load_news_items(socket) do
    items =
      Dashboard.list_news_items!()
      |> Enum.sort_by(&FamilyDashboard.NewsItem.effective_time/1, {:desc, DateTime})

    assign(socket, :news_items, items)
  end
```

- [ ] **Step 4: Restructure the layout to a column and render the ticker**

In `lib/family_dashboard_web/live/dashboard_live.ex`, replace `render/1`:

```elixir
  @impl true
  def render(assigns) do
    {hourly_min, hourly_max} = temp_bounds(hourly_temps(assigns.weather))
    {daily_min, daily_max} = daily_temp_bounds(daily_days(assigns.weather))

    assigns =
      assign(assigns,
        hourly_min: hourly_min,
        hourly_max: hourly_max,
        daily_min: daily_min,
        daily_max: daily_max,
        news_ticker_id: "news-ticker-#{news_items_key(assigns.news_items)}",
        marquee_duration: marquee_duration(assigns.news_items)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <!-- Portrait wall display (1080w x 1920h): 40% left rail, 60% right column,
           full-width news ticker pinned to the bottom. -->
      <div class="h-screen w-screen overflow-hidden bg-base-200 flex flex-col">
        <div class="flex-1 min-h-0 p-3 flex flex-row gap-2.5">
          <!-- Left rail (40%): clock/date, weather, weather alerts -->
          <div class="w-[40%] shrink-0 flex flex-col gap-3 overflow-hidden">
            <!-- Clock / greeting -->
            <section class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <p class="text-lg font-medium text-base-content/70">{@setting.greeting}</p>
                <p class="flex items-baseline gap-2.5 leading-none font-bold tabular-nums tracking-tight whitespace-nowrap">
                  <span class="text-[5.4rem] whitespace-nowrap">
                    <!-- Hour/colon/minute packed with no source whitespace between tags,
                         so HEEx doesn't insert a stray space between the digits. -->
                    <span class="inline-block min-w-[2ch] text-right">{Calendar.strftime(
                      @now,
                      "%-I"
                    )}</span><span class="inline-block -translate-y-[0.08em] animate-blink motion-reduce:animate-none">:</span><span class="inline-block">{Calendar.strftime(
                      @now,
                      "%M"
                    )}</span>
                  </span>
                  <span class="text-[1.7rem] font-semibold text-base-content/55">
                    {Calendar.strftime(@now, "%p")}
                  </span>
                </p>
                <p class="text-xl text-base-content/70 text-center">
                  {Calendar.strftime(@now, "%A, %B %-d")}
                </p>
              </div>
            </section>

            <!-- Current weather -->
            <section class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="Weather">
                  <:subtitle :if={@setting.city_label}>{@setting.city_label}</:subtitle>
                </.card_title>
                <div :if={@weather} class="flex flex-col gap-1">
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex items-center gap-3">
                      <span class="text-7xl">{weather_emoji(@weather.icon)}</span>
                      <p class="text-7xl font-bold tabular-nums">{round_temp(@weather.temp)}°</p>
                    </div>
                    <div class="text-right shrink-0">
                      <p :if={@weather.high && @weather.low} class="text-base text-base-content/60">
                        H {round_temp(@weather.high)}°
                      </p>
                      <p :if={@weather.high && @weather.low} class="text-base text-base-content/60">
                        L {round_temp(@weather.low)}°
                      </p>
                      <p class="text-base text-base-content/60">
                        feels {round_temp(@weather.feels_like)}°
                      </p>
                    </div>
                  </div>
                  <p class="text-base text-base-content/70 capitalize">{@weather.condition}</p>
                </div>
                <div :if={is_nil(@weather)}>
                  <p :if={@setting.weather_last_error} class="text-base text-warning">
                    Weather unavailable — {@setting.weather_last_error}
                  </p>
                  <p :if={is_nil(@setting.weather_last_error)} class="text-base text-base-content/50">
                    No weather data yet.
                  </p>
                </div>
              </div>
            </section>

            <!-- 8-hour forecast -->
            <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="8 hour" />
                <p :if={@weather.hourly == []} class="text-xs text-base-content/40">
                  Hourly forecast unavailable.
                </p>
                <div class="flex flex-col gap-2.5">
                  <div
                    :for={hour <- @weather.hourly}
                    class="grid grid-cols-[3.75rem_2.125rem_2.75rem_1fr_2.625rem] items-center gap-2 min-h-[2rem]"
                  >
                    <span class="text-lg font-semibold tabular-nums whitespace-nowrap">
                      <span class="inline-block min-w-[2ch] text-right">{hour_number(
                        hour.forecast_time,
                        @tz
                      )}</span>
                      <span>{hour_meridiem(
                        hour.forecast_time,
                        @tz
                      )}</span>
                    </span>
                    <span class="text-2xl text-center">{weather_emoji(hour.icon)}</span>
                    <span class="text-lg font-bold text-right tabular-nums">{round_temp(hour.temp)}°</span>
                    <span class="relative h-[7px] rounded-full bg-base-300">
                      <span
                        class="absolute inset-y-0 left-0 rounded-full"
                        style={hourly_bar_style(hour, @hourly_min, @hourly_max)}
                      ></span>
                    </span>
                    <span :if={pop_pct(hour.pop)} class="text-base text-info text-right tabular-nums">
                      {pop_pct(hour.pop)}%
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <!-- 7-day forecast -->
            <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="7-day" />
                <p :if={@weather.daily == []} class="text-xs text-base-content/40">
                  Daily forecast unavailable right now.
                </p>
                <div class="flex flex-col gap-2.5">
                  <div
                    :for={day <- @weather.daily}
                    class="grid grid-cols-[3.5rem_2.125rem_2.375rem_1fr_2.375rem_2.625rem] items-center gap-2 min-h-[2rem]"
                  >
                    <span class="text-lg font-semibold">{day_short_label(day.forecast_date, @today)}</span>
                    <span class="text-2xl text-center">{weather_emoji(day.icon)}</span>
                    <span class="text-lg text-base-content/70 text-right tabular-nums">{round_temp(
                      day.low
                    )}°</span>
                    <span class="relative h-[7px] rounded-full bg-base-300">
                      <span
                        class="absolute inset-y-0 rounded-full"
                        style={daily_range_style(day, @daily_min, @daily_max)}
                      ></span>
                      <span
                        class="absolute top-1/2 h-[13px] w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-sm bg-base-100 shadow-[0_0_0_1.5px_oklch(0%_0_0_/_0.25)]"
                        style={daily_avg_marker_style(day, @daily_min, @daily_max)}
                      ></span>
                    </span>
                    <span class="text-lg font-bold text-right tabular-nums">{round_temp(day.high)}°</span>
                    <span :if={pop_pct(day.pop)} class="text-base text-info text-right tabular-nums">
                      {pop_pct(day.pop)}%
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <!-- Weather Alerts -->
            <section :if={@active_alerts != []} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="Weather Alerts">
                  <:subtitle>{length(@active_alerts)}</:subtitle>
                </.card_title>
                <div class="flex flex-col gap-2">
                  <div
                    :for={alert <- @active_alerts}
                    class={"alert #{severity_color(alert.severity)} flex-col items-start gap-0.5 py-2"}
                  >
                    <div class="flex items-baseline justify-between gap-2 w-full">
                      <span class="font-semibold">{alert.name}</span>
                      <span class="text-sm opacity-80 shrink-0">{alert_until(alert.expires_at, @tz)}</span>
                    </div>
                    <p :if={@setting.alerts_show_body && alert.body} class="text-sm opacity-90">
                      {truncate_body(alert.body)}
                    </p>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <!-- Right column (60%): agenda -->
          <div class="flex-1 min-w-0 flex flex-col overflow-hidden">
            <!-- Agenda fills the remaining height; a single column clips at the bottom edge -->
            <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
              <div class="card-body min-h-0 overflow-hidden">
                <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
                <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
                  Nothing scheduled in the next {@agenda_days} days.
                </p>
                <div class="flex flex-col gap-y-4 overflow-hidden">
                  <div :for={{date, events} <- @events_by_day}>
                    <h3 class="text-2xl font-semibold text-base-content/80 border-b border-base-300 pb-1 mb-2">
                      {day_label(date, @today)}
                    </h3>
                    <ul class="space-y-2">
                      <li
                        :for={event <- events}
                        class="flex items-baseline gap-3 text-xl border-l-2 border-base-300 pl-3"
                        style={event_border_style(event)}
                      >
                        <span class="w-28 shrink-0 text-base-content/60 tabular-nums">
                          {event_time(event, @tz)}
                        </span>
                        <span class="font-medium">{event.title}</span>
                        <span :if={event.location} class="text-lg text-base-content/50 truncate">
                          · {event.location}
                        </span>
                      </li>
                    </ul>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </div>

        <!-- News ticker: content is server-driven (@news_items), motion is pure CSS.
             phx-update="ignore" + an items-derived id means a clock tick (unchanged
             items) never touches this node — the scroll keeps running uninterrupted;
             only a genuine news change (a different id) remounts it. -->
        <div
          :if={@news_items != []}
          id={@news_ticker_id}
          phx-update="ignore"
          class="shrink-0 w-full overflow-hidden bg-neutral text-neutral-content"
        >
          <div
            class="flex whitespace-nowrap animate-marquee py-2"
            style={"--marquee-duration: #{@marquee_duration}s"}
          >
            <span :for={item <- @news_items} class="flex items-center gap-2 pr-10 shrink-0">
              <span class="badge badge-sm badge-outline">{item.news_feed.label}</span>
              <span class="text-lg">{item.title}</span>
            </span>
            <span
              :for={item <- @news_items}
              class="flex items-center gap-2 pr-10 shrink-0"
              aria-hidden="true"
            >
              <span class="badge badge-sm badge-outline">{item.news_feed.label}</span>
              <span class="text-lg">{item.title}</span>
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
```

In the same file, add these two private functions immediately after `load_news_items/1`:

```elixir
  # A stable key derived from the current items' ids — used as (part of) the
  # ticker's DOM id. Unchanged across the 30s clock tick (same items, same
  # key, phx-update="ignore" leaves the node alone), but changes the moment
  # News.refresh_all/1 actually adds or removes an item, which remounts the
  # node and restarts the animation on genuinely new content.
  defp news_items_key(items), do: items |> Enum.map(& &1.id) |> :erlang.phash2()

  # Scrolls at a roughly constant reading speed regardless of how many
  # headlines are queued, instead of a fixed-duration animation that would
  # crawl with few headlines and blur past with many. Clamped to a 20s floor
  # so one or two short headlines don't zip by.
  @marquee_chars_per_second 10

  defp marquee_duration(items) do
    total_chars =
      items
      |> Enum.map(&(String.length(&1.title) + String.length(&1.news_feed.label)))
      |> Enum.sum()

    max(round(total_chars / @marquee_chars_per_second), 20)
  end
```

- [ ] **Step 5: Register the marquee's CSS animation**

In `assets/css/app.css`, replace the existing `@theme` block:

```css
@theme {
  --animate-blink: blink 1s steps(1, end) infinite;
  --animate-marquee: marquee var(--marquee-duration, 30s) linear infinite;
}
```

In the same file, add this immediately after the existing `@keyframes blink { ... }` block:

```css
/* The bottom news ticker's continuous scroll. Duration is driven by the
   `--marquee-duration` custom property set inline per-render (based on
   content length — see marquee_duration/1 in dashboard_live.ex), falling back
   to 30s if unset. The template renders the item track twice back-to-back;
   this animates exactly -50% (one copy's width) so the loop has no visible
   seam — the second copy is already in place to take over as the first
   scrolls off. */
@keyframes marquee {
  from {
    transform: translateX(0);
  }
  to {
    transform: translateX(-50%);
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the full test suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex assets/css/app.css test/family_dashboard_web/live/dashboard_live_test.exs
git commit -m "Render a bottom news ticker as a seamless, content-paced CSS marquee"
```

---

## Verification (end-to-end)

1. **Automated:** `mix test` — all tasks' tests plus the full pre-existing suite pass.
2. **Manual, on the running app:**
   - Start the app (`mix phx.server`), log into `/admin` (same shared password as `/ops`), and create a `NewsFeed` — e.g. `url: https://feeds.bbci.co.uk/news/rss.xml`, `label: BBC News`.
   - Go to `/ops`, click **Refresh news now**, confirm the News section shows `fetched <just now>` with no error.
   - Load `/` — confirm the chiron appears at the bottom, scrolling right-to-left, showing the source badge + headlines.
   - Watch it for over 60 seconds (past two 30s clock ticks) — confirm the scroll never stutters, jumps, or restarts from the beginning.
   - Add a second feed with an intentionally broken URL; refresh again from `/ops` — confirm the good feed's headlines still appear on the ticker and the broken feed shows its error in the News section, without the ticker losing any content.
