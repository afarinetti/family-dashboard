# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Phoenix/LiveView dashboard for a fixed **27" wall monitor in portrait**
(1080×1920) — a single always-on kiosk display, not a general-purpose
multi-user web app. It shows weather, an agenda (from synced iCal feeds), and
a scrolling news ticker. There is no user authentication for the dashboard
itself; a shared-password gate protects only the `/admin` and `/ops` areas.
Keep this "one fixed screen" framing in mind when touching layout/CSS — there
is no responsive/mobile concern, and "improve UX" generally means "improve
legibility from across a room," not conventional web ergonomics.

## Commands

```sh
mix setup                    # deps.get, ecto.setup (create+migrate+seed), assets.setup, assets.build
mix phx.server                # run the dev server (localhost:4000)
iex -S mix phx.server         # same, with a REPL attached

mix test                      # runs `ash.setup --quiet` first, then the suite
mix test test/path/to_test.exs
mix test test/path/to_test.exs:42   # single test at a line
mix test --failed

mix precommit                 # compile --warnings-as-errors, deps.unlock --unused, format, test
                               # ALWAYS run this before considering work done
mix format
```

Asset pipeline notes:
- `mix assets.build` runs `compile` + `tailwind family_dashboard` + `esbuild family_dashboard` — run it after any CSS/JS change (new Tailwind utility, new `@theme` token, new heroicon reference) to confirm the class/icon actually survives Tailwind's content scan and lands in `priv/static/assets/`. A typo'd or interpolated class name fails silently (no error anywhere) rather than raising.
- `mix assets.deploy` is the minified prod variant (`phx.digest` at the end).

Dev data lives in `family_dashboard_dev.db` (SQLite) at the repo root — safe to inspect directly, but prefer seeding/clearing through the `Dashboard` Ash domain (see below) rather than hand-editing rows, since Ash resources may have derived/validated fields.

## Architecture

### Ash Framework, not bare Ecto

Every domain concept is an **Ash resource** under `lib/family_dashboard/` (e.g.
`calendar.ex`, `event.ex`, `weather_reading.ex`, `weather_alert.ex`,
`setting.ex`, `news_feed.ex`), backed by `ash_sqlite`. `lib/family_dashboard/dashboard.ex`
is the single `Ash.Domain` and is the **only sanctioned entry point** for
reading/writing this data — it `define`s a code interface (e.g.
`Dashboard.create_weather_alert!/1`, `Dashboard.latest_weather/0`,
`Dashboard.current_setting/0`) that LiveViews, workers, and tests all call
instead of touching `Ecto.Query`/`Repo` or resource modules directly. When
adding a new field/action to a resource, also add its `define` to
`dashboard.ex` if callers need it.

`Setting` is a **singleton** — one row holds location, greeting, sync
intervals, and alert-filtering thresholds, read live by `Heartbeat` and the
dashboard LiveView. There's no seed-on-first-request path: if the row doesn't
exist (fresh DB with no seed run), weather/greeting silently stay blank. See
"First-boot seed" in `deploy/README.md`.

### Data flow: Heartbeat → Oban workers → Sync → Ash resources → PubSub → LiveView

- `FamilyDashboard.Heartbeat.run/0` fires every minute (an `ash_oban` scheduled
  action) and enqueues per-source Oban workers (`lib/family_dashboard/workers/`)
  only when that source's configured interval has actually elapsed — intervals
  live in the `Setting` row, so cadence is admin-editable without a redeploy.
  The `/ops` page's manual "sync now" buttons call the same `enqueue_*`
  functions with `force?: true` to bypass each worker's Oban uniqueness window.
- Workers call into `FamilyDashboard.Sync`, which is deliberately
  transaction-careful: the network fetch happens *before* any DB write (so a
  transient HTTP failure can't roll back a `last_error` write), `last_error` is
  recorded in its own transaction, and PubSub broadcasts fire only *after
  commit* so a rolled-back sync never pushes phantom data to the wall display.
- `FamilyDashboardWeb.DashboardLive` subscribes to those PubSub topics and to a
  30s clock tick; assigns like `@active_alerts` are recomputed on *both* triggers
  (see `assign_active_alerts/1`) so an admin's filter edit or an alert's
  natural expiry take effect within 30s without waiting for the next sync.

### Weather providers are pluggable behind one contract

`lib/family_dashboard/weather/provider.ex` defines the behaviour every
adapter (`xweather.ex` — default, `open_weather.ex` — alternate, set via
`WEATHER_PROVIDER` env var) must normalize onto: `fetch_current_and_hourly/4`,
`fetch_daily/4`, `fetch_alerts/4`. `FamilyDashboard.Weather` dispatches to
whichever is configured; `Sync`, the resources, and the LiveView only ever see
the normalized shape, never a provider's raw response. Read the moduledoc in
`provider.ex` before touching either adapter — it documents non-obvious unit
gotchas (e.g. `:pop` must be a 0.0–1.0 fraction; Xweather's native API reports
it as a percentage and must be divided by 100 in `normalize_*`, or every
probability renders 100x too large in the UI).

Alert severity is normalized to four tokens: `extreme` > `severe` > `moderate`
> `minor` (ranked in `severity_rank/1`, `dashboard_live.ex`). Alerts are
filtered by `Setting.alerts_min_severity` OR shown anyway if their `category`
is in `Setting.alerts_always_show_categories` (life-safety categories like
heat/flood/tornado bypass the severity gate, since providers sometimes rate
advisory-tier products below the default threshold).

### `dashboard_live.ex` is one large LiveView, not split into components

`lib/family_dashboard_web/live/dashboard_live.ex` (~1000+ lines) holds the
entire dashboard's markup (inline `~H`) and all its presentation helper
functions — there's no separate `.heex` file and few extracted function
components (`card_title/1`, `weather_alert/1` are the exceptions). This is
existing, accepted structure (see `TODO.md` item 17, "Extract card widgets
into separate functional components" — not yet done); don't reflexively
refactor it into components as a drive-by while doing something else, but
extracting a section you're already substantially rewriting is fine.

Tailwind v4's content scanner and the heroicons plugin only emit CSS/icons for
class and icon names that appear **literally** in source — never build one
via interpolation (`"bg-#{token}"`, `"hero-#{name}"`). The established pattern
throughout this file is a `defp` function that pattern-matches each known
value to a hardcoded literal string (see `alert_tone/1`, `alert_badge/1`,
`alert_icon/1`, `severity_label/1`), the same way `@color_shade_hex` handles
the agenda's arbitrary calendar colors. A miswritten interpolated class fails
**silently** — no compile error, no runtime error, the class or icon just
never appears in the built CSS/JS. After adding one, verify with
`mix assets.build` then `grep` the compiled `priv/static/assets/css/app.css`
for the literal string, rather than trusting `mix compile` alone.

### Styling: Tailwind v4 + daisyUI (despite `AGENTS.md` saying otherwise)

`AGENTS.md`'s generic Phoenix boilerplate says to hand-roll Tailwind
components and avoid daisyUI "for a unique world-class design" — **this
project does not follow that generic advice**. It uses daisyUI's component
classes (`card`, `alert`, `badge`, `btn`, etc.) and two custom daisyUI themes
(`dark` — Elixir-purple, `prefersdark: true`; `light` — Phoenix-colors,
default) defined via OKLCH tokens in `assets/css/app.css`. Prefer daisyUI
semantic tokens (`bg-base-100`, `text-primary`, `alert-error`, etc.) over raw
hex for anything that should respect both themes. Custom animations (the
clock's blinking colon, the news ticker's marquee, the alert pulse) are
registered as `--animate-*` tokens inside `@theme` so Tailwind auto-generates
the corresponding `animate-*` utility, rather than hand-written `@layer
utilities` classes — follow that existing convention for new animations.

### Ops/admin surface

`/admin` (AshAdmin — manage calendars, news feeds, settings) and `/ops`
(`OpsLive` — manual sync triggers, sync status, backup download) both sit
behind `FamilyDashboardWeb.Plugs.SettingsAuth`, a shared-password Basic Auth
gate (`SETTINGS_USERNAME`/`SETTINGS_PASSWORD`). The root `/` dashboard route
is deliberately **not** behind this gate — the kiosk must never hit a login
screen. `/oban` (Oban Web) is behind the same gate.

Backups (`FamilyDashboard.Backup`) write a daily JSON snapshot to
`/data/backups` and are also downloadable on demand via
`GET /ops/backup.json`.

### Deployment target (see `deploy/README.md` for the full runbook)

Ships as a container to an **Ubuntu Core** kiosk device via the Canonical
`docker` snap (not Podman/Quadlet — strict confinement on Core breaks both).
GitHub Actions (`.github/workflows/ci.yml`) builds with `docker buildx` and pushes to
`ghcr.io/<org>/family_dashboard` using the built-in `GITHUB_TOKEN` — no PAT/repo
secrets required. Persistence is a **named Docker volume**,
never a host bind-mount (arbitrary bind-mount paths silently fail on
strictly-confined Core snaps). Releases run migrations automatically at boot
whenever `RELEASE_NAME` is set (see `skip_migrations?/0` in
`FamilyDashboard.Application`) — there's no `rel/` overlay. This deploy
intentionally serves **plain HTTP** (`force_ssl` removed from `config/prod.exs`)
and disables LiveView's `check_origin`, since the kiosk browser talks to
`localhost:4000` directly.

## Elixir/Phoenix conventions from `AGENTS.md`

`AGENTS.md` at the repo root has the full generic Phoenix/Ash usage-rules
(Elixir idioms, Phoenix v1.8/LiveView specifics, HEEx syntax gotchas, testing
patterns). Highlights worth internalizing rather than re-reading every time:

- Run `mix precommit` when done with changes, not just `mix test`.
- Use `Req` for HTTP; never `httpoison`/`tesla`/`httpc`.
- Always use the `<.icon name="hero-...">` component for icons — never
  `Heroicons` modules directly.
- HEEx `class` attrs needing conditionals **must** use list syntax:
  `class={["base", @flag && "extra"]}`.
- Avoid `LiveComponent`s unless there's a specific need (none currently used
  in this codebase).
- LiveView tests: prefer `element/2`/`has_element/2` over raw HTML string
  matching where practical — though note the existing alert tests in
  `dashboard_live_test.exs` do assert on rendered text content directly, which
  is the established pattern for this file.
