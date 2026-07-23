# Family Dashboard

A Phoenix/LiveView dashboard built to run on a single wall-mounted display: current
weather and an 8-hour/7-day forecast, an agenda pulled from one or more iCal calendar
feeds, active weather alerts, and a scrolling news ticker. It's designed for a fixed
27" monitor in portrait orientation (1080x1920) as a kiosk, but runs fine in any
browser window for development.

There's no login for the dashboard itself — it's meant to be glanced at, not
interacted with. A separate password-gated area handles configuration and
operations.

## Features

- **Weather** — current conditions, an 8-hour forecast strip, and a 7-day
  outlook. Feels-like temperature is shown where it meaningfully diverges from
  the actual temperature. Supports two providers (Xweather and OpenWeatherMap),
  selectable via configuration; the dashboard degrades gracefully (blank
  weather panel, rest of the dashboard unaffected) if no provider is configured
  or a fetch fails.
- **Weather alerts** — active alerts from the provider are shown as cards
  colored and weighted by severity (minor/moderate get a soft tint, severe/extreme
  get a bold fill, extreme or emergency alerts pulse). Alerts are sorted by
  severity, then by soonest-ending first. Which alerts appear is configurable
  (see Settings below).
- **Agenda** — events from any number of iCal (`.ics`) calendar feeds, merged
  into a single upcoming view spanning today plus the next three weeks. Each
  calendar has its own display color. Past events are hidden rather than shown
  dimmed; events are periodically pruned once they age out of the window.
- **News ticker** — a continuously scrolling ticker at the bottom of the
  screen, fed by one or more RSS/Atom feeds. Scroll speed and retention window
  are configurable.
- **Ops hub** (`/ops`) — manual "sync now" triggers for weather, calendars,
  and news; a status panel showing last-attempted/last-error per source; and
  backup/restore of calendars and settings to/from a JSON file.
- **Admin** (`/admin`) — an [Ash Admin](https://hexdocs.pm/ash_admin) UI for
  managing calendars, news feeds, and the settings record directly.
- **Job monitoring** (`/oban`) — [Oban Web](https://hexdocs.pm/oban_web) for
  inspecting the background jobs that drive all of the above.

## Settings

All of the following live in a single `Setting` record, editable at `/admin`
(there's exactly one row; it must exist before weather/greeting will show —
see Setup below).

| Setting | Purpose |
|---|---|
| `latitude` / `longitude` | Location used for weather lookups |
| `city_label` | Display name for the location |
| `units` | Unit system for weather values |
| `time_zone` | IANA time zone (e.g. `America/Chicago`) used to compute "today" and display times |
| `greeting` | Optional text shown on the dashboard |
| `calendar_sync_minutes` | How often calendars are re-synced |
| `weather_refresh_minutes` | How often current/hourly weather is refreshed |
| `daily_refresh_minutes` | How often the 7-day forecast is refreshed (separate cadence — that endpoint is slower-changing and less reliable) |
| `sync_max_attempts` | Retry limit for a sync job before it gives up |
| `alerts_min_severity` | Minimum severity (`minor`, `moderate`, `severe`, `extreme`) an alert must meet to display |
| `alerts_hidden_categories` | Comma-separated alert categories to always hide, regardless of severity |
| `alerts_always_show_categories` | Comma-separated alert categories that always display regardless of severity (defaults to life-safety categories like heat, flood, tornado, since providers sometimes rate advisory-tier products below the default minimum severity) |
| `alerts_show_body` | Whether alert cards show the full alert text or just the name and expiration |
| `news_refresh_minutes` | How often news feeds are refreshed |
| `news_retention_hours` | How long a news item is kept before being pruned |
| `news_ticker_chars_per_second` | Ticker scroll speed |

Calendars and news feeds are managed separately at `/admin`, each with its own
URL, an enabled/active flag, and (for calendars) a display color.

## Setup

Requires Elixir, and SQLite (via `ecto_sqlite3` — no separate database server
to install or run).

```sh
mix setup
```

This installs dependencies, creates and migrates the database, seeds it (this
creates the one required `Setting` row), and builds frontend assets.

Copy `.env.example` to `.env` and fill in the values you want. `.env` is
gitignored and loaded automatically by `mix phx.server` (via `dotenvy`). All
values are optional — the dashboard runs without any of them, just with
weather disabled and default admin credentials.

- `WEATHER_PROVIDER` — `xweather` (default) or `openweather`
- `XWEATHER_CLIENT_ID` / `XWEATHER_CLIENT_SECRET` — credentials for the
  default provider ([xweather.com](https://www.xweather.com))
- `WEATHER_API_KEY` — API key for OpenWeatherMap, if using that provider
  instead ([openweathermap.org](https://openweathermap.org/api); note its
  daily forecast endpoint reliably omits icon/condition data)
- `SETTINGS_USERNAME` / `SETTINGS_PASSWORD` — credentials for the `/admin`
  and `/ops` password gate (defaults to `family` / `family-dashboard` in dev
  and test; required in production)
- `PORT` — HTTP port (defaults to 4000)

Once the server is running, set the actual location, greeting, and calendar
feeds at `/admin`.

## Running

```sh
mix phx.server
```

or, with a REPL attached:

```sh
iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) for the dashboard,
`/admin` for calendar/news/settings configuration, and `/ops` for manual
sync controls and backups.

## Testing

```sh
mix test
```

Run a single file with `mix test test/path/to_test.exs`, or a single test with
`mix test test/path/to_test.exs:LINE`.

Before considering a change complete, run:

```sh
mix precommit
```

This compiles with warnings as errors, removes unused dependency locks,
formats, and runs the test suite.

## Shortcuts

A `justfile` wraps the commands above via [`just`](https://github.com/casey/just).
Run `just` with no arguments to list everything available:

```sh
just setup         # mix setup
just server        # mix phx.server
just console       # iex -S mix phx.server
just test          # mix test
just test-one test/family_dashboard_web/live/dashboard_live_test.exs        # single file
just test-one test/family_dashboard_web/live/dashboard_live_test.exs 42     # single test at a line
just test-failed   # mix test --failed
just precommit     # mix precommit
just format        # mix format
just assets        # mix assets.build
just db-reset      # mix ecto.reset
just seed          # re-run priv/repo/seeds.exs
```

## Deployment

This project is set up to run as a container on an Ubuntu Core kiosk device,
with images built by GitHub Actions and published to GitHub Container Registry. See
[`deploy/README.md`](deploy/README.md) for the full runbook, including
first-boot setup, updating, backups, and troubleshooting.

## Learn more about the underlying frameworks

- Phoenix: https://www.phoenixframework.org/, https://phoenix.hexdocs.pm
- Ash Framework: https://ash-hq.org, https://hexdocs.pm/ash
