# Dashboard Layout Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the wall-display dashboard into a 30/70 two-column layout (narrow left rail for clock/weather/placeholders, wide right column for a single-column agenda) and add a calendar-colored left border to each agenda event.

**Architecture:** Pure `render/1` + CSS change to the existing `FamilyDashboardWeb.DashboardLive` LiveView. No changes to `mount/3`, `handle_info/2`, assigns, or data loading. Three sequential tasks: (1) build the two-column shell and resized left rail, (2) convert the agenda from a 2-column grid to a single clipped column, (3) add the per-event calendar color border. Each task keeps the existing test suite green and is independently reviewable.

**Tech Stack:** Phoenix LiveView, HEEx templates, Tailwind CSS v4, daisyUI 5, Ash Framework (read-only in this plan — no resource changes), ExUnit + Phoenix.LiveViewTest.

## Global Constraints

- Pure `render/1` + CSS/HEEx change — do not modify `mount/3`, `handle_info/2`, `assign_*`, `load_weather/1`, `load_events/1`, or any presentation helper's *logic* (only new helpers may be added).
- No scrollbars anywhere on the display — use `overflow-hidden` for clipping, never `overflow-y-auto`, on any container in this template.
- Left rail is 30% width, right column is 70%, split via `flex flex-row` on the outer container (currently `flex flex-col`).
- Use daisyUI's `card-sm` size modifier for compact left-rail cards instead of manual `card-body` padding overrides (per this project's daisyUI skill: size modifiers are the idiomatic way to shrink component padding; custom Tailwind text-size utilities remain fine for content).
- Per this project's daisyUI color rules, raw Tailwind color names (e.g. `orange-600`) are normally avoided in favor of daisyUI semantic tokens (`primary`, `info`, etc.) *except* when content must stay visually consistent regardless of theme — which is exactly the calendar-identity-color case here, so this is an accepted, intentional exception, not a shortcut.
- Verify at the real display resolution: render at a 1080×1920 browser viewport before considering any task's visual work done.

---

## Task 1: Two-column shell + resized left rail

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex:114-233` (the entire `render/1` function)
- Test: `test/family_dashboard_web/live/dashboard_live_test.exs` (no new tests — existing suite must stay green)

**Interfaces:**
- Consumes: existing assigns only (`@setting`, `@now`, `@today`, `@weather`, `@events_by_day`, `@agenda_days`, `@tz`), existing helpers (`weather_emoji/1`, `round_temp/1`, `hour_label/2`, `day_short_label/3`, `pop_pct/1`, `day_label/2`, `event_time/2`) — all unchanged, no new signatures introduced.
- Produces: the outer two-column shell (`flex flex-row`) that Task 2 and Task 3 build inside. The agenda section keeps its current `grid grid-cols-2` markup unchanged in this task, just relocated into the new right-column wrapper — Task 2 converts it to a single column.

This task does NOT touch the agenda's internal markup — it only rebuilds the clock/weather/placeholder stack into a narrower left rail and wraps the (still 2-column) agenda in a new right-column `<div>`. This keeps the diff reviewable and avoids doing agenda work twice.

- [ ] **Step 1: Run the existing test suite to confirm the baseline is green**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: All tests PASS (this is the baseline before any template changes).

- [ ] **Step 2: Replace `render/1` with the two-column shell**

Replace the full `render/1` function (`lib/family_dashboard_web/live/dashboard_live.ex:114-233`) with:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <!-- Portrait wall display (1080w x 1920h): 30% left rail, 70% right column. -->
      <div class="h-screen w-screen overflow-hidden bg-base-200 p-6 flex flex-row gap-5">
        <!-- Left rail (30%): clock/date, weather, news/alerts placeholders -->
        <div class="w-[30%] shrink-0 flex flex-col gap-3 overflow-hidden">
          <!-- Clock / greeting -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <p class="text-lg font-medium text-base-content/70">{@setting.greeting}</p>
              <p class="text-5xl leading-none font-bold tabular-nums tracking-tight">
                {Calendar.strftime(@now, "%-I:%M")}
                <span class="text-2xl font-semibold text-base-content/60">
                  {Calendar.strftime(@now, "%p")}
                </span>
              </p>
              <p class="text-xl text-base-content/70">{Calendar.strftime(@now, "%A, %B %-d")}</p>
            </div>
          </section>

          <!-- Current weather -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">
                Weather<span :if={@setting.city_label} class="font-normal">· {@setting.city_label}</span>
              </h2>
              <div :if={@weather} class="flex items-center gap-3">
                <span class="text-5xl">{weather_emoji(@weather.icon)}</span>
                <p class="text-4xl font-bold tabular-nums">{round_temp(@weather.temp)}°</p>
                <div>
                  <p class="text-base text-base-content/70 capitalize">{@weather.condition}</p>
                  <p :if={@weather.high && @weather.low} class="text-sm text-base-content/60">
                    H {round_temp(@weather.high)}° · L {round_temp(@weather.low)}°
                  </p>
                  <p class="text-sm text-base-content/60">feels {round_temp(@weather.feels_like)}°</p>
                </div>
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

          <!-- Hourly (next 8 hours) -->
          <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60 mb-1">Next hours</h2>
              <p :if={@weather.forecast["hourly"] in [nil, []]} class="text-xs text-base-content/40">
                Hourly forecast unavailable.
              </p>
              <div class="flex justify-between gap-0.5">
                <div
                  :for={hour <- @weather.forecast["hourly"] || []}
                  class="flex flex-col items-center gap-0.5 flex-1"
                >
                  <span class="text-[0.6rem] text-base-content/60">{hour_label(hour["dt"], @tz)}</span>
                  <span class="text-xl">{weather_emoji(hour["icon"])}</span>
                  <span class="text-xs font-semibold tabular-nums">{round_temp(hour["temp"])}°</span>
                  <span :if={pop_pct(hour["pop"])} class="text-[0.6rem] text-info">{pop_pct(hour["pop"])}%</span>
                </div>
              </div>
            </div>
          </section>

          <!-- 7-day -->
          <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60 mb-1">7-day</h2>
              <p :if={@weather.forecast["days"] in [nil, []]} class="text-xs text-base-content/40">
                Daily forecast unavailable right now.
              </p>
              <div class="flex justify-between gap-0.5">
                <div
                  :for={day <- @weather.forecast["days"] || []}
                  class="flex flex-col items-center gap-0.5 flex-1"
                >
                  <span class="text-[0.6rem] text-base-content/60">{day_short_label(day["dt"], @tz, @today)}</span>
                  <span class="text-xl">{weather_emoji(day["icon"])}</span>
                  <span class="text-xs font-semibold tabular-nums">{round_temp(day["high"])}°</span>
                  <span class="text-[0.55rem] text-base-content/50 tabular-nums">{round_temp(day["low"])}°</span>
                </div>
              </div>
            </div>
          </section>

          <!-- News (placeholder, not yet wired to data) -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">News</h2>
              <p class="text-xs text-base-content/40">Coming soon.</p>
            </div>
          </section>

          <!-- Weather Alerts (placeholder, not yet wired to data) -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">Weather Alerts</h2>
              <p class="text-xs text-base-content/40">Coming soon.</p>
            </div>
          </section>
        </div>

        <!-- Right column (70%): agenda -->
        <div class="flex-1 min-w-0 flex flex-col overflow-hidden">
          <!-- Agenda fills the remaining height; two columns fit the portrait width -->
          <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
            <div class="card-body min-h-0">
              <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
              <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
                Nothing scheduled in the next {@agenda_days} days.
              </p>
              <div class="grid grid-cols-2 gap-x-10 gap-y-4 overflow-y-auto content-start">
                <div :for={{date, events} <- @events_by_day} class="break-inside-avoid">
                  <h3 class="text-2xl font-semibold text-base-content/80 border-b border-base-300 pb-1 mb-2">
                    {day_label(date, @today)}
                  </h3>
                  <ul class="space-y-2">
                    <li :for={event <- events} class="flex items-baseline gap-3 text-xl">
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
    </Layouts.app>
    """
  end
```

- [ ] **Step 3: Run the test suite again to confirm nothing broke**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: All tests PASS (same assertions as Step 1 — the assigns and rendered text content haven't changed, only markup/classes around them).

- [ ] **Step 4: Manual visual check of the left rail**

Run: `mix phx.server`, open `http://localhost:4000` in a browser resized/emulated to a 1080×1920 viewport (e.g. Chrome DevTools device toolbar with a custom 1080×1920 size).

Confirm:
- The page is split into a visibly narrower left column and wider right column, roughly 30/70.
- No section in the left rail wraps its text onto an extra line unexpectedly or overflows its card horizontally.
- No scrollbar appears anywhere on the page.
- If the hourly or 7-day strip's text is too small to read comfortably, note it — this is the checkpoint flagged in the design spec for possibly reducing item count or switching to a vertical list, which is out of scope for this task but should be reported before moving on.

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex
git commit -m "Rebuild dashboard as a 30/70 two-column shell with a resized left rail"
```

---

## Task 2: Single-column agenda

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex` (the agenda `<section>` inside the right-column `<div>` produced by Task 1 — look for the `<!-- Agenda fills the remaining height... -->` comment)
- Test: `test/family_dashboard_web/live/dashboard_live_test.exs` (no new tests — existing suite must stay green)

**Interfaces:**
- Consumes: `@events_by_day`, `@agenda_days`, `@today`, `@tz`, `day_label/2`, `event_time/2` — all unchanged from Task 1.
- Produces: a single-column, `overflow-hidden` agenda list that Task 3 adds the event border to (specifically, the `<li :for={event <- events} ...>` element).

- [ ] **Step 1: Run the existing test suite to confirm the baseline (post-Task-1) is green**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: All tests PASS.

- [ ] **Step 2: Replace the agenda section's grid with a single column**

Find this block (inside the right-column `<div>` from Task 1):

```elixir
          <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
            <div class="card-body min-h-0">
              <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
              <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
                Nothing scheduled in the next {@agenda_days} days.
              </p>
              <div class="grid grid-cols-2 gap-x-10 gap-y-4 overflow-y-auto content-start">
                <div :for={{date, events} <- @events_by_day} class="break-inside-avoid">
```

Replace it with:

```elixir
          <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
            <div class="card-body min-h-0 overflow-hidden">
              <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
              <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
                Nothing scheduled in the next {@agenda_days} days.
              </p>
              <div class="flex flex-col gap-y-4 overflow-hidden">
                <div :for={{date, events} <- @events_by_day}>
```

(Everything below this — the `<h3>` day header, the `<ul>`/`<li>` event list, and the closing `</div>`/`</section>` tags — stays exactly as-is; only the container's classes and the two opening lines change. `grid grid-cols-2 gap-x-10 gap-y-4 overflow-y-auto content-start` becomes `flex flex-col gap-y-4 overflow-hidden`, and `break-inside-avoid` is dropped since it's a CSS-columns/print concept that doesn't apply to a flex column. `overflow-y-auto` on the card-body becomes `overflow-hidden` too.)

- [ ] **Step 3: Run the test suite again to confirm nothing broke**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: All tests PASS — event titles ("Piano lesson", "Birthday party") and empty/error states still appear in the rendered HTML regardless of column layout.

- [ ] **Step 4: Manual visual check of the agenda**

With `mix phx.server` still running (or restarted) at the 1080×1920 viewport from Task 1:

Confirm:
- "Upcoming" is now a single column spanning the right column's width, not two side-by-side columns.
- No scrollbar appears on the agenda card or the page.
- If there are enough seeded events to overflow the visible area, the list clips cleanly at the bottom edge of the screen rather than showing a scrollbar or an obviously cut-off partial line of text right at the edge (a slightly clipped icon/line at the very edge is acceptable per the design's "clip at the container edge" choice — a scrollbar appearing is not).

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex
git commit -m "Switch the agenda from a 2-column grid to a single clipped column"
```

---

## Task 3: Calendar-colored event border

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex` (add a module attribute + helper function, and update the event `<li>`)
- Test: `test/family_dashboard_web/live/dashboard_live_test.exs` (add 3 new tests)

**Interfaces:**
- Consumes: `event.calendar.color` (nullable `:string`, already preloaded by `Event`'s `in_window` read via `load: [:calendar]` — see `lib/family_dashboard/event.ex:31`). No new Ash queries.
- Produces: `event_border_style/1`, a private helper on `FamilyDashboardWeb.DashboardLive` taking an event struct and returning either a `"border-left-color: var(--color-#{color})"` string or `nil`. This is internal to this module — no other module calls it.

- [ ] **Step 1: Write the failing tests**

Add these three tests to `test/family_dashboard_web/live/dashboard_live_test.exs` (place them near the other agenda-related tests, e.g. after the "shows synced calendar events" test):

```elixir
  test "colors an event's border using its calendar's Tailwind color", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)

    calendar =
      Dashboard.create_calendar!(%{
        name: "Family",
        ical_url: "https://x/cal.ics",
        color: "orange-600"
      })

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "border-left-color: var(--color-orange-600)"
  end

  test "falls back to a neutral border when the calendar has no color", %{conn: conn} do
    day = Date.add(Date.utc_today(), 1)
    calendar = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "border-left-color"
    assert html =~ "border-base-300"
  end

  test "falls back to a neutral border when the calendar color isn't a valid Tailwind shade", %{
    conn: conn
  } do
    day = Date.add(Date.utc_today(), 1)

    calendar =
      Dashboard.create_calendar!(%{
        name: "Family",
        ical_url: "https://x/cal.ics",
        color: "javascript:alert(1)"
      })

    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: "e1",
      title: "Piano lesson",
      starts_at: DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "border-left-color"
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: The 3 new tests FAIL. The first fails because `"border-left-color: var(--color-orange-600)"` isn't in the rendered HTML yet; the second and third currently pass trivially (no test yet asserts `border-base-300` is present on the `<li>`), so confirm specifically that the first new test fails with an `Assertion with =~ failed` error before continuing.

- [ ] **Step 3: Add the color-shade allowlist and helper function**

In `lib/family_dashboard_web/live/dashboard_live.ex`, add a module attribute near the top of the module, alongside the existing `@tick_ms`/`@agenda_days` attributes (around line 12-13):

```elixir
  @tick_ms 30_000
  @agenda_days 7

  # Matches only real Tailwind CSS default palette color-shade pairs (e.g. "orange-600"),
  # so an untrusted DB value can never be interpolated into an arbitrary CSS var() name.
  @color_shade_regex ~r/^(slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-(50|100|200|300|400|500|600|700|800|900|950)$/
```

Then add the helper function in the "presentation helpers" section (after `event_time/2`, around where `hour_label/2` is defined in the current file):

```elixir
  # A calendar's identity color must render as the same hue on every theme (see
  # the daisyUI color rules' theme-independence exception), so it's rendered via the
  # raw Tailwind CSS variable rather than a daisyUI semantic token. The stored value
  # is untrusted (nullable, unconstrained DB text) and must never crash this always-on
  # display, so it's validated against a strict allowlist before being used at all.
  defp event_border_style(%{calendar: %{color: color}}) when is_binary(color) do
    if Regex.match?(@color_shade_regex, color) do
      "border-left-color: var(--color-#{color})"
    end
  end

  defp event_border_style(_event), do: nil
```

- [ ] **Step 4: Wire the helper into the event `<li>`**

Find the event `<li>` inside the agenda (produced by Task 2):

```elixir
                    <li :for={event <- events} class="flex items-baseline gap-3 text-xl">
```

Replace it with:

```elixir
                    <li
                      :for={event <- events}
                      class="flex items-baseline gap-3 text-xl border-l-2 border-base-300 pl-3"
                      style={event_border_style(event)}
                    >
```

(`border-base-300` is always present as the class-level fallback color; when `event_border_style/1` returns a style string, the inline `style` attribute's `border-left-color` overrides it for that element. When it returns `nil`, Phoenix omits the `style` attribute entirely and `border-base-300` is what renders.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: All tests PASS, including the 3 new ones.

- [ ] **Step 6: Manual visual check of event borders**

With `mix phx.server` running:
- Using `iex -S mix` or a seed script, set two different calendars' `color` to two different valid values (e.g. `"orange-600"` and `"blue-500"`), and confirm their events show visibly different colored left borders on the dashboard.
- Confirm an event whose calendar has no color (`nil`) shows a neutral gray border, not an error or a missing border.

- [ ] **Step 7: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex test/family_dashboard_web/live/dashboard_live_test.exs
git commit -m "Add a calendar-colored left border to agenda events"
```
