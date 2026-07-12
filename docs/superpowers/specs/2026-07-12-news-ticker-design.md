# Bottom News Ticker (Chiron) — Design

## Context

The dashboard is a 24/7 wall display (portrait, 1080×1920) that currently shows
clock/greeting, weather (current, hourly, 7-day, alerts) in a 40% left rail and
an agenda in the 60% right column. TODO #3 asks to "move news to a
ticker/chiron at the bottom." There is **no news feature in the codebase today** —
an earlier plan (`docs/superpowers/plans/2026-07-11-weather-alerts-and-hide-news-design.md`)
removed the old "News — coming soon" placeholder card entirely. So this is a
brand-new feature, built from scratch.

The goal: a full-width scrolling news chiron along the bottom of the display,
fed by operator-configured RSS/Atom feeds, that reuses the app's established
data-pipeline shape (external source → normalizing adapter → Oban worker gated
by the minute `Heartbeat` → persisted Ash resource → `DashboardLive` render via
a PubSub topic → daily reaper). Motion is client-side CSS; the server only owns
content.

## Decisions (settled during brainstorming)

- **Source:** operator-configured RSS/Atom feeds (no API key).
- **Feed config:** a `NewsFeed` Ash resource with `ash_admin` CRUD (parallels `Calendar`).
- **Headline storage:** persisted `NewsItem` resource **with a reaper** (parallels weather).
- **Presentation:** a **continuous marquee**; each item is a daisyUI `badge`
  (source label) + the headline; items merged **newest-first** across feeds.
- **RSS parsing:** a small **pure-Elixir feed parser** hex dep — the exact
  library to be vetted by `hex-library-researcher` during writing-plans (must
  handle RSS 2.0 + Atom, and decode HTML entities/CDATA in titles).
- **Retention:** **time window** (default ~24h), but always keep the latest item
  per feed so the ticker never blanks — mirrors `WeatherReaper`'s protect-latest rule.

## Architecture

Near-clone of the weather stack. New pieces:

**Resources** (`lib/family_dashboard/`)
- `news_feed.ex` — `NewsFeed`: `url`, `label`, `enabled?` (operator-editable);
  `last_fetched_at`, `last_error` (system-set, for observability like the
  weather status fields). `has_many :items`. Register in `dashboard.ex` domain.
- `news_item.ex` — `NewsItem`: `title`, `url`, `guid`, `published_at`,
  `belongs_to :news_feed`. **Dedup identity is `[news_feed_id, guid]`, falling
  back to `url`** — not `guid` alone (guids collide across feeds). An upsert on
  that identity so re-fetches don't duplicate.

**Fetch pipeline**
- `lib/family_dashboard/news.ex` — `Req.get(feed.url)` → pure-Elixir feed
  parser → normalized item maps `%{title, url, guid, published_at}`. This is the
  same "normalize to plain maps" seam the `Weather.Provider` adapters use; keep
  parsing isolated here so the resource/worker stay parser-agnostic.
- `lib/family_dashboard/workers/news_refresh.ex` — an Oban worker enqueued by
  the existing minute-cadence `Heartbeat` (`lib/family_dashboard/heartbeat.ex`),
  gated on a new `news_refresh_minutes` `Setting` (default 15, matching weather).
  Follows the `weather_refresh.ex` worker shape.
- **Per-feed best-effort + carry-forward:** each *enabled* feed is fetched
  independently; one feed failing must not block the others. On failure, record
  `last_error` on that `NewsFeed` and **keep its existing items** (a stale
  headline is harmless — the opposite tradeoff from weather alerts, which are
  never carried forward). After a refresh cycle, `broadcast("news", :news_updated)`
  via the existing `Sync.broadcast/2`-style helper.

**Reaper**
- `lib/family_dashboard/news_reaper.ex` — daily Oban cron (register alongside
  `weather_reap`/`backup` in `config/config.exs`). Deletes `NewsItem`s where the
  effective timestamp is older than the retention window, **but always keeps the
  newest item per feed**. Mirrors `WeatherReaper` (protect-latest so the ticker
  never empties). Add a `news_retention_hours` `Setting` (default 24).

**`published_at` fallback (load-bearing — both sort and reaper depend on it)**
- Many RSS items have no `pubDate`; Atom uses `published`/`updated`. When the
  parsed `published_at` is `nil`, **coalesce to `inserted_at`** (fetch time) for
  both the newest-first ordering and the retention comparison. Do not let a nil
  timestamp silently sort to the bottom or get reaped instantly / kept forever.

**Settings** (`lib/family_dashboard/setting.ex`)
- Add `news_refresh_minutes` (int, default 15, min 1) and `news_retention_hours`
  (int, default 24, min 1) to `@writable`, mirroring the existing `*_minutes`
  scheduling knobs. Standard `mix ash.codegen` migration.

**Render — the chiron** (`lib/family_dashboard_web/live/dashboard_live.ex`)
- Restructure the root `div` (currently `h-screen w-screen overflow-hidden flex
  flex-row`) into a **`flex-col`**: wrap the existing 40/60 `flex-row` content in
  a `flex-1 min-h-0` region, and add a full-width fixed-height ticker bar below
  it as `shrink-0`. The bar is **hidden when there are zero items** (gated like
  the existing `@active_alerts != []` alerts card), so the agenda reclaims the
  space when there's no news.
- Marquee track: items merged newest-first; each item = a daisyUI `badge`
  (`@news_item.news_feed.label`) + headline text, separated by dots. The headline
  track is **duplicated back-to-back** inside the animated container and
  translated by exactly `-50%`, so the loop is seamless (copy #2 enters as copy
  #1 exits — no gap on wrap).
- **Motion is pure CSS** via a new `--animate-marquee` keyframe registered in
  `assets/css/app.css`'s `@theme` block — the same precedent as the existing
  `--animate-blink` clock colon. The animation utility name must appear
  **literally** in source (Tailwind's scanner only compiles literal class
  strings — see the `@color_shade_hex` note in `dashboard_live.ex`).
- **Constant reading speed:** a fixed-duration keyframe scrolls the whole track
  in that time, so a few headlines crawl and many blur. Keep it pure-CSS *and*
  constant by having the server emit `style={"--marquee-duration: #{secs}s"}`
  computed from total content length (character count), with the CSS using
  `animation-duration: var(--marquee-duration)`. Fits "server owns content,
  browser owns motion."
- **Prevent animation restart on the 30s clock tick:** the LiveView re-renders
  every 30s. The marquee subtree must reference **only `@news_items`** (never the
  clock/time assigns), so an unchanged item list produces no DOM diff and the
  scroll keeps running. Insure this with a keyed wrapper (`id` derived from a
  hash/count of the current items) + `phx-update="ignore"`, so only a genuine
  news change replaces the node. (The `animate-blink` precedent does NOT cover
  this — a sub-second blink restart is invisible; a 40s scroll restart is not.)
- Subscribe to the `"news"` PubSub topic in the `connected?` block at `mount`
  and add `handle_info(:news_updated, ...)` to reload items — mirroring the
  existing `:weather_updated` / `:events_updated` clauses.

**Security**
- Headline/source text is untrusted feed content. HEEx auto-escapes, so it is
  safe **as long as nobody uses `raw/1`** on it — the plan must never render feed
  text through `raw`. The feed parser must decode HTML entities / CDATA in titles.

## Critical files

New: `lib/family_dashboard/news_feed.ex`, `news_item.ex`, `news.ex`,
`news_reaper.ex`, `lib/family_dashboard/workers/news_refresh.ex`.
Modify: `lib/family_dashboard/dashboard.ex` (register resources + code
interfaces), `setting.ex` (2 new settings), `heartbeat.ex` (enqueue news
refresh when due), `config/config.exs` (reaper cron), `mix.exs` (feed-parser
dep), `dashboard_live.ex` (root flex-col restructure + ticker render + news
topic/handle_info), `assets/css/app.css` (`--animate-marquee` keyframe).

## Reuse (existing patterns to follow, not reinvent)

- Resource shape + domain registration: `weather_alert.ex`, `dashboard.ex`.
- Adapter "normalize to plain maps" seam: `weather/provider.ex` + `xweather.ex`.
- Worker + `Heartbeat` due-gating on a `*_minutes` setting:
  `workers/weather_refresh.ex`, `heartbeat.ex`.
- Reaper protect-latest rule + daily cron: `weather_reaper.ex`, `config/config.exs`.
- PubSub broadcast + `handle_info` render refresh: `sync.ex`, `dashboard_live.ex`.
- CSS animation via `@theme` token: existing `--animate-blink` in `app.css`.
- Operator-editable scalar settings + `@writable`: `setting.ex`.

## Verification (end-to-end)

- **Unit/TDD (per resource + pipeline):** `mix test` — feed parsing (RSS + Atom,
  missing `pubDate`, entity/CDATA decode), dedup upsert on `[news_feed_id, guid]`,
  per-feed best-effort (one feed fails, others persist), carry-forward on failure,
  reaper time-window + protect-latest, newest-first ordering with `inserted_at`
  fallback. Follow the Xweather-shaped `Req.Test` plug convention in
  `test/family_dashboard/sync_test.exs`.
- **LiveView test:** `dashboard_live_test.exs` — ticker renders items when
  present, is absent when there are none, and shows the source badge label.
- **Manual on the running app:** seed a `NewsFeed` (e.g. BBC RSS) via `/admin`,
  force a refresh from the ops hub (`ops_live.ex` "sync now" pattern), and load
  `/` — confirm the chiron scrolls smoothly at a readable pace, loops seamlessly,
  and does **not** stutter/restart across a 30s clock tick (watch it for >60s).
