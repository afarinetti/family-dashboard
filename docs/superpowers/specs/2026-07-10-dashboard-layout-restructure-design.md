# Dashboard layout restructure: 30/70 split + event color borders

**Date:** 2026-07-10
**Status:** Approved, ready for implementation plan

## Context

The wall-display dashboard (`FamilyDashboardWeb.DashboardLive`, portrait 1080×1920 on a
fixed 27" monitor) currently stacks everything in one vertical column: clock/greeting,
current weather, hourly forecast (8 items), 7-day forecast (7 items), then a 2-column
agenda grid with `overflow-y-auto` for the next 7 days of events.

This restructures the display into two columns and adds a per-calendar color indicator
to agenda events.

This is a `render/1` + CSS change only. `mount/3`, `handle_info/2`, all assigns, and all
presentation helper functions in `dashboard_live.ex` are unchanged — no new data is
loaded, no existing data flow changes.

## Layout: 30/70 two-column split

The outer container changes from `flex flex-col` to `flex flex-row`, producing:

```
┌─────────────┬──────────────────────────────────┐
│  Left rail  │           Right column            │
│    (30%)    │              (70%)                │
│  ~310px     │             ~722px                │
│             │                                    │
│  Clock/date │   Upcoming (single column)         │
│  Weather:   │     Today                          │
│   current   │       9:00 AM  Event                │
│   hourly    │       2:00 PM  Event                │
│   7-day     │     Tomorrow                        │
│  News (ph)  │       ...                           │
│  Alerts(ph) │     Wed, Jul 15                      │
│             │       ...                            │
│             │   (clipped at the bottom edge,       │
│             │    no scrollbar, if content runs      │
│             │    past the visible area)             │
└─────────────┴──────────────────────────────────┘
```

Both columns are independently `flex flex-col overflow-hidden` — no scrollbars anywhere
on this display. Sections within each column are `shrink-0` and top-aligned. The left
rail is expected to have vertical slack once the agenda is removed from it (empty space
at the bottom is acceptable); no section flexes to fill remaining height.

## Left rail (30%, ~310px wide)

Top to bottom:

1. **Clock/date** — same content (greeting, time, AM/PM, full date), font sizes reduced
   from the current full-width scale (`text-[8.5rem]` time) to roughly `text-6xl`/`text-7xl`
   for time, with greeting/date scaled down correspondingly, to fit ~310px without
   wrapping.
2. **Current weather** — same layout (icon, temp, condition, high/low, feels-like),
   icon/temp reduced from `text-9xl`/`text-8xl` to roughly `text-5xl`/`text-6xl`.
3. **Hourly forecast** — same horizontal strip, all 8 items retained, icon/temp/label
   sizes reduced to fit ~245px of usable width (card padding eats part of the 310px
   rail width). This is the one dimension that can't be validated from code alone —
   8 items in that width is tight (~30px/item). **Verification requirement:** render at
   the real 1080×1920 viewport and visually confirm legibility from typical wall-display
   viewing distance. If illegible, revisit reducing item count or stacking vertically
   (both declined this round in favor of "keep all, shrink").
4. **7-day forecast** — same horizontal strip, all 7 items retained, same shrink
   treatment as hourly.
5. **News** — new empty placeholder card, same `card bg-base-100 shadow-sm` styling as
   other sections, muted "Coming soon" label, no data wiring.
6. **Weather Alerts** — same treatment as News, placeholder only.

## Right column (70%, ~722px wide) — Upcoming agenda

Same data source (`@events_by_day`, `@agenda_days = 7`, unchanged `load_events/1`).
Container changes from `grid grid-cols-2 gap-x-10 gap-y-4 overflow-y-auto` to
`flex flex-col gap-y-4 overflow-hidden` — a single column instead of two.

No scrollbar, no per-day truncation logic: whatever day sections and events fit above
the bottom edge render in full; anything past that edge is clipped by the container's
`overflow-hidden`. Event row styling (time / title / location) is unchanged, just wider
since it no longer shares horizontal space with a second column.

## Event color border

Each agenda event `<li>` gets a 2px colored left border indicating its source calendar.

- `event.calendar.color` is a nullable, unconstrained `:string` on `FamilyDashboard.Calendar`
  (`calendar.ex:50-52`), already preloaded via the `in_window` read (`event.ex:31`) — no
  new query needed.
- The value is a Tailwind palette `color-shade` string (e.g. `"orange-600"`, `"blue-500"`),
  populated manually by the user (no writer exists in the sync worker; this is set
  directly in the DB today).
- **Rendering approach (corrected after final review — see note below):** inline
  `style="border-left-color: #{resolved_color}"`, where `resolved_color` is looked up
  from a static Elixir map of Tailwind's default palette resolved to literal `oklch()`
  values, NOT a dynamically-built Tailwind utility class and NOT a `var(--color-...)`
  reference. Tailwind v4's content scanner only generates CSS — including the
  underlying theme *variables*, not just utility classes — for identifiers it finds as
  literal strings in scanned source. A class or `var()` name assembled via string
  interpolation (`"border-#{color}"`, `var(--color-#{color})`) is never scanned, so
  Tailwind never emits it, and the reference silently resolves to nothing at runtime
  (an inline `border-left-color: var(--undefined-var)` computes to `currentcolor`, not
  an error). Storing the resolved color values directly in the app sidesteps this
  build-time dependency entirely.

  > **Correction (post-implementation):** this section originally claimed theme CSS
  > variables "are emitted unconditionally by Tailwind's base theme layer regardless of
  > content scanning." That claim was wrong for this project's actual build output and
  > was never verified against it at design time — it was a general assumption about
  > Tailwind v4, not a checked fact. The final whole-branch review caught it by
  > rebuilding `app.css` and confirming zero `--color-<name>-<shade>` variables exist in
  > the compiled output (this app never writes a literal `border-<color>-<shade>` class
  > anywhere in source, so Tailwind's scanner never discovers a reason to generate the
  > corresponding variable). The bug shipped past task-level review because the tests
  > asserted the literal HTML string (`html =~ "var(--color-orange-600)"`), which stayed
  > true whether or not the browser could actually resolve that variable — the tests
  > never proved the border rendered the right color, only that the attribute text was
  > present. The fix extracts the real values from Tailwind's own build output (via the
  > standalone CLI, referencing every `border-<color>-<shade>` utility in a scratch file
  > so the scanner materializes all 242 combinations) rather than typing them from
  > memory, and was verified with `getComputedStyle(li).borderLeftColor` in a real
  > browser render, in both the light and dark theme.
- **Validation:** before use, `color` is checked against a strict allowlist pattern
  matching Tailwind's actual palette names and shades (e.g.
  `^(slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-(50|100|200|300|400|500|600|700|800|900|950)$`).
  This mirrors the existing "never trust a stored value at render time" pattern already
  used for time zones (`safe_zone/1`) — the display must not crash on bad data.
- **Fallback:** nil, blank, or malformed `color` values render a neutral
  `border-l-2 border-base-300` instead of the inline style, so every event gets a
  consistent border rather than an inconsistent colored/uncolored look.
- **Known trade-off:** raw Tailwind color-shade values are a fixed hue in both the light
  and dark theme (unlike DaisyUI semantic tokens, which would adapt automatically). This
  was an explicit, informed choice — the data is already populated this way.

## Verification

No new business logic, so no new unit tests. Verification is visual:

- Start `mix phx.server`, load the dashboard in a browser sized to 1080×1920.
- Confirm no scrollbars appear anywhere on the page.
- Confirm hourly/7-day forecast strips are legible at the reduced size.
- Confirm the agenda clips cleanly at the bottom edge (no awkward mid-event-row cut).
- Seed 2-3 calendars with different color values and confirm event borders render the
  correct color, and that an event with a nil/invalid calendar color falls back cleanly.
