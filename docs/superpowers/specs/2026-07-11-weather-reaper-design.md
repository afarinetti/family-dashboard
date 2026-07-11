# Weather Reaper Design

## Context

Weather normalization (see `docs/superpowers/plans/2026-07-11-admin-ops-enhancements.md`, Tasks 1–4) split forecast data out of an opaque JSON blob into `WeatherHourly`/`WeatherDaily` child resources belonging to `WeatherReading`. Every refresh — the fast current+hourly job runs on a `weather_refresh_minutes` cadence, default 30 minutes — *creates a new* `WeatherReading` row plus ~8 `WeatherHourly` children and up to 7 carried-forward `WeatherDaily` children; nothing ever prunes old readings. This growth pattern predates the normalization work (the old code created a new reading every cycle too), but splitting the forecast into child tables multiplied the row count per reading roughly 15x. The final review of that plan flagged this as a legitimate, non-blocking follow-up. This spec adds the follow-up: a scheduled job that reaps old weather data.

Only the single *latest* `WeatherReading` is ever read anywhere in the app (`WeatherReading.latest` powers both the wall dashboard and the ops status panel) — older readings have no read path and exist purely as accumulated history.

## Decisions

- **Retention is time-based**, not count-based: readings older than a fixed window are eligible for reaping. Self-adjusting if refresh intervals in Settings change later.
- **Retention window: 48 hours**, hardcoded as a module attribute (matching the existing convention of `@window_days 21` in `Sync` and `@hours`/`@days` in `Weather` — an internal implementation constant, not a user-facing Settings knob).
- **The current latest reading is always protected**, regardless of age. If weather refreshes break for an extended period (API outage, bad key), the dashboard keeps showing the last-known reading with its `weather_last_error` surfaced, rather than reaping down to nothing and showing "No weather data yet."
- **Schedule: daily**, via the same `Oban.Plugins.Cron` config entry that already runs the backup job (`"0 3 * * *"`) — deletion is cheap; no need for a tighter loop.

## Architecture

Mirrors the existing `Backup` / `Workers.Backup` split (Task 10/11 of the admin-ops plan): a pure logic module plus a thin Oban worker.

- **`FamilyDashboard.WeatherReaper`** (new) — pure module, no LiveView/controller dependency. `reap/0` does the actual deletion, in one `Repo.transaction`:
  1. Look up the current latest reading's `id` via `Dashboard.latest_weather()` (returns `{:ok, nil}` if no readings exist yet — nothing to protect in that case).
  2. Query `WeatherReading` ids where `observed_at` is older than `now - 48h`, excluding the protected id if one exists.
  3. **Guard the empty case explicitly** before building the children filter: Ash resolves `id in []` to "match nothing" — the same gotcha `Sync.replace_window_events` already documents and guards against for calendar-event pruning. If the reap set is empty, skip straight to returning `:ok`.
  4. Bulk-destroy `WeatherHourly` and `WeatherDaily` rows whose `weather_reading_id` is in the reap set (children first — no DB-level or Ash-level cascade exists on either FK, confirmed in the normalize_weather migration).
  5. Bulk-destroy the `WeatherReading` rows themselves.

- **`FamilyDashboard.Workers.WeatherReap`** (new) — thin Oban worker (`queue: :default, max_attempts: 3`), `perform/1` delegates to `WeatherReaper.reap/0`.

- **`config/config.exs`** (modify) — add a second `{"0 3 * * *", FamilyDashboard.Workers.WeatherReap}` tuple to the existing `Oban.Plugins.Cron` `crontab:` list (alongside `FamilyDashboard.Workers.Backup`).

## Data Flow

```
Oban cron (daily, 03:00)
  → Workers.WeatherReap.perform/1
    → WeatherReaper.reap/0
      → Dashboard.latest_weather()              (find the protected id)
      → query WeatherReading ids older than 48h, excluding protected id
      → [empty? return :ok]
      → bulk-destroy WeatherHourly  where weather_reading_id in ids
      → bulk-destroy WeatherDaily   where weather_reading_id in ids
      → bulk-destroy WeatherReading where id in ids
```

No PubSub broadcast — reaping old, unread history is invisible to the dashboard and the ops panel by construction (neither ever reads anything but the latest reading), so there's nothing for a live view to react to.

## Error Handling

Reap logic runs inside a single `Repo.transaction` — a failure partway through rolls back cleanly, leaving the data exactly as it was before the job ran (matching `Sync.replace_window_events`'s and `Sync.apply_daily_to_latest`'s existing transaction discipline). The Oban worker's `perform/1` lets any raised error propagate normally so Oban's standard retry/max_attempts handling applies — consistent with `Workers.Backup`.

## Testing

- `test/family_dashboard/weather_reaper_test.exs`: create readings at varying ages (well within the window, well outside it, exactly at the boundary) with hourly/daily children; assert old readings and their children are gone, in-window readings are untouched, and the latest reading survives even when constructed to be older than the window. Also cover the empty-database case (no readings at all — must not raise).
- `test/family_dashboard/workers/weather_reap_test.exs`: `perform_job/2` delegates to `WeatherReaper.reap/0` (mirrors `workers/backup_test.exs`'s shape).
- No LiveView/controller test needed — this feature has no UI surface.

## Out of Scope

- No manual "reap now" trigger on `/ops` — this is routine background maintenance, not an operator action like the existing sync triggers.
- No configurable retention window in Settings — YAGNI until there's a concrete need to tune it per-deployment.
