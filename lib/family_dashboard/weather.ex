defmodule FamilyDashboard.Weather do
  @moduledoc """
  Dispatches to whichever weather provider is configured, so the rest of the
  app (`Sync`, the LiveViews, the resources) depends only on the normalized
  shape documented in `FamilyDashboard.Weather.Provider` — never on a specific
  provider's HTTP API.

  The active adapter is chosen at boot via
  `config :family_dashboard, :weather_provider` (see `config/runtime.exs`,
  driven by the `WEATHER_PROVIDER` env var), defaulting to
  `FamilyDashboard.Weather.Xweather`. Swapping providers is a config change,
  not a code change — `FamilyDashboard.Weather.OpenWeather` remains available
  by setting `WEATHER_PROVIDER=openweather`.
  """

  @doc "Fetches current conditions + the hourly forecast. See `Provider.fetch_current_and_hourly/4`."
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []),
    do: provider().fetch_current_and_hourly(lat, lon, units, opts)

  @doc "Fetches the 7-day forecast. See `Provider.fetch_daily/4`."
  @spec fetch_daily(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_daily}
  def fetch_daily(lat, lon, units, opts \\ []), do: provider().fetch_daily(lat, lon, units, opts)

  @doc "Fetches active weather alerts. See `Provider.fetch_alerts/4`."
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(lat, lon, units, opts \\ []),
    do: provider().fetch_alerts(lat, lon, units, opts)

  @doc "Whether the currently configured provider has the credentials it needs to make requests."
  @spec credentials_configured?() :: boolean()
  def credentials_configured?, do: provider().credentials_configured?()

  @spec provider() :: module()
  defp provider do
    Application.get_env(:family_dashboard, :weather_provider, FamilyDashboard.Weather.Xweather)
  end
end
