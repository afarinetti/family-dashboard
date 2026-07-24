# Meteocons (vendored subset)

Source: https://github.com/basmilius/meteocons (`@meteocons/svg` npm package,
`fill` style), MIT licensed — see `LICENSE`.

Only the ~14 icons this app actually uses are vendored (not the full 475+ icon
set), split into two directories:

- `animated/` — the SVGs exactly as published, including their built-in SMIL
  `<animate>`/`<animateTransform>` elements. Used for the current-weather card.
- `static/` — the same SVGs with the SMIL animation elements stripped, so the
  icon renders motionless at a representative frame. A few icons animate
  elements in *from* `opacity="0"` (e.g. staggered raindrops/snowflakes); the
  generation step also drops those zero-opacity base states so the static
  frame shows the icon fully "populated" rather than mid-animation-start.
  Used for the 8-hour and 7-day forecast rows.

Regenerating `static/` from `animated/` (if the vendored source is ever
updated): strip `<animate ...\/>` / `<animateTransform ...\/>` tags and any
now-orphaned `opacity="0"` attributes from each file.

## Cropped viewBox for the cloud-based icons

`cloudy`, `partly-cloudy-day`, `drizzle`, `rain`, and `thunderstorms` share
the same "single cloud" artwork, which only fills ~51%x40% of the original
128x128 canvas (vs. ~75%x75% for e.g. `clear-day`'s sun) — it reads as
noticeably smaller than other conditions at the same icon size. All five
have their `viewBox` cropped from `0 0 128 128` to `14 13 100 100` (same
crop on both `animated/` and `static/` copies, so an icon looks identical in
the current-weather card and the forecast rows, just animated vs. not).

That window was chosen to safely contain everything that moves, not just
the resting artwork: `drizzle`/`rain`'s falling drops translate up to 20px
past their resting position, but fade to `opacity="0"` in sync with
reaching it, so the ~2px of travel the crop clips is already
imperceptible; `partly-cloudy-day`'s sun rotates a full circle, but its
rays (~21px from their pivot) stay well inside the window at every angle.
If a future vendor update changes any of this artwork or animation, re-verify
those two margins before reusing this crop value.

## Filename → weather condition token mapping

See `lib/family_dashboard_web/components/weather_icons.ex`.
