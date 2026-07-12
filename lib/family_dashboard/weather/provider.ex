defmodule FamilyDashboard.Weather.Provider do
  @moduledoc """
  The contract every weather data source (OpenWeatherMap, Xweather, ...) must satisfy.

  `FamilyDashboard.Weather` dispatches to whichever adapter is configured
  (`config :family_dashboard, :weather_provider`) and the rest of the app —
  `Sync`, the LiveViews, the resources — depends only on this normalized shape,
  never on a provider's raw HTTP response. That's what makes providers swappable:
  every adapter maps its own API onto the same keys below.

  ## `fetch_current_and_hourly/4`

  Returns `{:ok, attrs}` where `attrs` is a reading map plus a nested `:hourly`
  list, or `{:error, reason}`. Reading keys:

    * `:observed_at`, `:sunrise`, `:sunset` — `DateTime.t()` or `nil`
    * `:temp`, `:feels_like` — numbers (already in the caller's requested units)
    * `:condition` — human-readable text (e.g. `"overcast clouds"`)
    * `:icon` — a normalized icon token (see below), or `nil`
    * `:humidity`, `:pressure`, `:dew_point`, `:uvi`, `:clouds`, `:visibility`,
      `:wind_speed`, `:wind_deg`, `:wind_gust` — numbers or `nil` if the
      provider doesn't supply them (these are stored but not every field is
      rendered, so `nil` is harmless)
    * `:location_label` — a display name for the location, or `nil`
    * `:hourly` — a list of maps (up to 8, nearest-first), each with:
      `:forecast_time` (`DateTime.t()`), `:temp`, `:feels_like`, `:pop`,
      `:humidity`, `:wind_speed`, `:icon` (normalized token), `:condition`

  ## `fetch_daily/4`

  Returns `{:ok, days}` where `days` is a non-empty list (up to 7, nearest-first)
  of maps with: `:forecast_date` (`DateTime.t()`), `:high`, `:low`, `:pop`,
  `:summary`, `:humidity`, `:wind_speed`, `:sunrise`, `:sunset`, `:icon`
  (normalized token), `:condition` — or `{:error, :no_daily}` if the provider
  has nothing for this location.

  `:pop` (in both shapes above) is a **0.0-1.0 fraction**, not a 0-100
  percentage — the render layer (`dashboard_live.ex`'s `pop_pct/1`) multiplies
  by 100 itself. A provider whose native API reports pop as a percentage (e.g.
  Xweather) must divide by 100 before returning it, or every value renders 100x
  too large.

  ## `fetch_alerts/4`

  Returns `{:ok, alerts}` where `alerts` is a list of maps (one per currently
  active alert for this location), or `{:error, :no_alerts}` if the provider
  has none. Each alert map:

    * `:alert_type` — the provider's raw alert code, kept for debugging/display
      (e.g. Xweather's `"AW.TS.MD"`), or `nil`
    * `:severity` — normalized to one of `"extreme" | "severe" | "moderate" |
      "minor"` — never a raw provider severity value
    * `:priority` — a provider-specific numeric rank, lower is more
      significant, or `nil`
    * `:category` — a short category token (e.g. `"thunderstorm"`), or `nil`
    * `:name` — the alert's title (e.g. `"Severe Thunderstorm Warning"`)
    * `:body` — human-readable alert text, or `nil`
    * `:color` — the provider's official hex color for this alert, or `nil`
    * `:emergency` — boolean, or `nil`
    * `:begins_at`, `:expires_at`, `:issued_at` — `DateTime.t()` or `nil`

  Unlike `fetch_daily/4`'s carry-forward behavior in `Sync`, alert data is
  never carried forward from a previous refresh — a failed or empty
  `fetch_alerts/4` call must result in zero displayed alerts, since a stale
  severe-weather warning is far more harmful than a stale forecast.

  ## Icon tokens

  `:icon` values are one of the provider-neutral strings below (or `nil`),
  never a provider-specific code. Storing neutral tokens means a `WeatherDaily`
  row rendered by `dashboard_live.ex`'s `weather_emoji/1` doesn't care which
  provider produced it — important since providers can be swapped via config
  without a data migration:

    "clear" | "partly_cloudy" | "cloudy" | "rain" | "showers" |
    "thunderstorm" | "snow" | "fog" |
    "tornado" | "hurricane" | "blizzard" | "ice_storm"

  The last four are severe/exotic conditions, kept distinct from their nearest
  everyday token (tornado/hurricane from thunderstorm; blizzard/ice_storm from
  snow) precisely because a family dashboard should make them visually stand
  out rather than blend into "stormy" or "snowy" — see each adapter's `icon/1`
  for how reliably that provider's data can detect them (Xweather's text
  description names these explicitly; OpenWeatherMap's compact icon vocabulary
  can only reliably distinguish tornado, not hurricane).

  An adapter that can't confidently map a provider code to one of these tokens
  should return `nil` rather than guess — `weather_emoji/1` already has a
  distinct fallback for "no data" (nil) versus "code we don't recognize".

  ## Credentials

  `credentials_configured?/0` reports whether this adapter has what it needs
  (API key, or client id + secret) to make requests, so `Sync` can skip
  fetching and record a clear status message instead of guaranteed HTTP failures.
  """

  @type lat :: number()
  @type lon :: number()
  @type units :: String.t()
  @type opts :: keyword()

  @callback fetch_current_and_hourly(lat, lon, units, opts) :: {:ok, map()} | {:error, term()}
  @callback fetch_daily(lat, lon, units, opts) :: {:ok, [map()]} | {:error, :no_daily}
  @callback fetch_alerts(lat, lon, units, opts) :: {:ok, [map()]} | {:error, :no_alerts}
  @callback credentials_configured?() :: boolean()
end
