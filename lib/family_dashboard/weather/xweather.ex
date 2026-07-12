defmodule FamilyDashboard.Weather.Xweather do
  @moduledoc """
  Facade around the Xweather Weather API (`https://data.api.xweather.com`,
  formerly AerisWeather — same underlying API). Two calls per refresh:

    * `/conditions/{lat},{lon}`               — current conditions
    * `/forecasts/{lat},{lon}?filter=1hr`     — hourly forecast (next 8 hours)

  ...plus one more for the separate daily job:

    * `/forecasts/{lat},{lon}?filter=day`     — daily forecast (next 7 days)

  Implements `FamilyDashboard.Weather.Provider` — see that module for the
  normalized shape this adapter must return.

  Unlike OpenWeatherMap's One Call 4.0 `/timeline/1day` (which reliably returns
  `"weather": null` for every day — see `FamilyDashboard.Weather.OpenWeather`'s
  moduledoc), Xweather's `/forecasts` endpoint returns a real `icon` and
  `weather` text description for **both** hourly and daily periods, which is
  the whole reason this adapter is now the default provider.

  Every response shares the same envelope:
  `%{"success" => bool, "error" => map | nil, "response" => [%{"periods" => [...], "place" => %{...}, ...}]}`.

  Responses carry both Fahrenheit/mph and Celsius/kph fields; this adapter
  selects which to read based on the `units` argument (`"imperial"` vs
  anything else, matching the OpenWeatherMap adapter's convention) — there is
  no `units` query param to set.

  Auth is a `client_id` + `client_secret` query param pair
  (`XWEATHER_CLIENT_ID` / `XWEATHER_CLIENT_SECRET`), not a single API key.
  """

  @behaviour FamilyDashboard.Weather.Provider

  @base_url "https://data.api.xweather.com"

  @hours 8
  @days 7
  @hourly_timeout 8_000
  @daily_timeout 15_000

  @impl true
  def credentials_configured?, do: not is_nil(client_id()) and not is_nil(client_secret())

  @doc """
  Fetches current conditions + the hourly forecast for `lat`/`lon`. The hourly
  call is best-effort (mirrors the OpenWeatherMap adapter) — a slow/failing
  forecast call drops the `:hourly` list rather than failing the whole refresh.
  """
  @impl true
  @spec fetch_current_and_hourly(number(), number(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_current_and_hourly(lat, lon, units, opts \\ []) do
    with {:ok, current} <- get("/conditions/#{place(lat, lon)}", [], opts) do
      hourly =
        best_effort(
          "/forecasts/#{place(lat, lon)}",
          [filter: "1hr", limit: @hours],
          opts,
          @hourly_timeout
        )

      {:ok, normalize_current(current, hourly, units)}
    end
  end

  @doc """
  Fetches the 7-day forecast. Xweather's `/forecasts` is a first-class,
  reliable endpoint (unlike OWM's flaky daily timeline), so — unlike the
  OpenWeatherMap adapter — this doesn't need a retry loop.
  """
  @impl true
  @spec fetch_daily(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_daily}
  def fetch_daily(lat, lon, units, opts \\ []) do
    opts = Keyword.put_new(opts, :receive_timeout, @daily_timeout)

    case get("/forecasts/#{place(lat, lon)}", [filter: "day", limit: @days], opts) do
      {:ok, body} ->
        case periods(body) do
          [] -> {:error, :no_daily}
          periods -> {:ok, daily_summary(periods, units)}
        end

      {:error, _} ->
        {:error, :no_daily}
    end
  end

  @doc """
  Fetches active weather alerts for `lat`/`lon`. Returns `{:ok, :no_alerts}`
  when the location has none.
  """
  @impl true
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(lat, lon, _units, opts \\ []) do
    case get("/alerts/#{place(lat, lon)}", [], opts) do
      {:ok, body} ->
        case body["response"] || [] do
          [] -> {:error, :no_alerts}
          alerts -> {:ok, Enum.map(alerts, &normalize_alert/1)}
        end

      {:error, _} ->
        {:error, :no_alerts}
    end
  end

  defp place(lat, lon), do: "#{lat},#{lon}"

  defp get(path, params, opts) do
    base = [
      base_url: @base_url,
      url: path,
      params: params ++ [client_id: client_id(), client_secret: client_secret()],
      retry: false
    ]

    case Req.get(Keyword.merge(base, opts)) do
      {:ok, %Req.Response{status: 200, body: %{"success" => true} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: %{"success" => false} = body}} ->
        {:error, {:api_error, body["error"]}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp best_effort(path, params, opts, timeout) do
    opts = Keyword.put_new(opts, :receive_timeout, timeout)

    case get(path, params, opts) do
      {:ok, body} -> body
      {:error, _} -> %{}
    end
  end

  # `response` is a list (one entry per requested place); we only ever request
  # one place, so take its `periods` list.
  defp periods(body) do
    (body["response"] || []) |> List.first(%{}) |> Map.get("periods", [])
  end

  defp normalize_current(current, hourly, units) do
    period = current |> periods() |> List.first() || %{}
    place = current |> Map.get("response", []) |> List.first(%{}) |> Map.get("place")

    %{
      observed_at: parse_timestamp(period["timestamp"]),
      temp: period[temp_field(units)],
      feels_like: period[feelslike_field(units)],
      condition: period["weather"],
      icon: icon(period["weather"]),
      humidity: round_int(period["humidity"]),
      pressure: round_int(period["pressureMB"]),
      dew_point: period[dew_point_field(units)],
      uvi: period["uvi"],
      clouds: round_int(period["sky"]),
      visibility: round_int(period[visibility_field(units)]),
      wind_speed: period[wind_speed_field(units)],
      wind_deg: round_int(period["windDirDEG"]),
      wind_gust: period[wind_gust_field(units)],
      # /conditions doesn't return sunrise/sunset (only /forecasts does, via
      # sunriseISO/sunsetISO — see daily_summary/2); neither is rendered on the
      # reading itself, so nil here is harmless.
      sunrise: nil,
      sunset: nil,
      location_label: place_label(place),
      hourly: hourly_summary(hourly, units)
    }
  end

  defp hourly_summary(hourly, units) do
    hourly
    |> periods()
    |> Enum.take(@hours)
    |> Enum.map(fn period ->
      %{
        forecast_time: parse_timestamp(period["timestamp"]),
        temp: period[temp_field(units)],
        feels_like: period[feelslike_field(units)],
        pop: pop_fraction(period["pop"]),
        humidity: round_int(period["humidity"]),
        wind_speed: period[wind_speed_field(units)],
        icon: icon(period["weather"]),
        condition: period["weather"]
      }
    end)
  end

  defp daily_summary(periods, units) do
    periods
    |> Enum.take(@days)
    |> Enum.map(fn period ->
      %{
        forecast_date: parse_timestamp(period["timestamp"]),
        high: period[max_temp_field(units)],
        low: period[min_temp_field(units)],
        pop: pop_fraction(period["pop"]),
        summary: period["weather"],
        humidity: round_int(period["humidity"]),
        wind_speed: period[wind_speed_field(units)],
        sunrise: parse_iso(period["sunriseISO"]),
        sunset: parse_iso(period["sunsetISO"]),
        icon: icon(period["weather"]),
        condition: period["weather"]
      }
    end)
  end

  defp normalize_alert(alert) do
    details = alert["details"] || %{}
    timestamps = alert["timestamps"] || %{}

    %{
      alert_type: details["type"],
      severity: alert_severity(details["type"]),
      priority: details["priority"],
      category: details["cat"],
      name: details["name"],
      body: details["body"],
      color: details["color"],
      emergency: details["emergency"] || false,
      begins_at: parse_timestamp(timestamps["begins"]),
      expires_at: parse_timestamp(timestamps["expires"]),
      issued_at: parse_timestamp(timestamps["issued"])
    }
  end

  # Xweather's alert `type` code is a dot-separated string whose final segment
  # is a severity abbreviation (EX/SV/MD/MN) — see
  # https://www.xweather.com/docs/weather-api/endpoints/alerts. Normalized to
  # the closed set documented in FamilyDashboard.Weather.Provider so filter
  # config never depends on the raw provider code. Falls back to "minor"
  # (the least alarming tier) rather than crashing on an unrecognized code,
  # since `severity` is a required (`allow_nil? false`) attribute.
  defp alert_severity(nil), do: "minor"

  defp alert_severity(type) when is_binary(type) do
    case type |> String.split(".") |> List.last() do
      "EX" -> "extreme"
      "SV" -> "severe"
      "MD" -> "moderate"
      "MN" -> "minor"
      _ -> "minor"
    end
  end

  defp alert_severity(_), do: "minor"

  defp place_label(%{"name" => name, "state" => state, "country" => "us"})
       when is_binary(name) and is_binary(state) do
    "#{String.capitalize(name)}, #{String.upcase(state)}"
  end

  defp place_label(%{"name" => name}) when is_binary(name), do: String.capitalize(name)
  defp place_label(_), do: nil

  defp temp_field("imperial"), do: "tempF"
  defp temp_field(_), do: "tempC"
  defp max_temp_field("imperial"), do: "maxTempF"
  defp max_temp_field(_), do: "maxTempC"
  defp min_temp_field("imperial"), do: "minTempF"
  defp min_temp_field(_), do: "minTempC"
  defp feelslike_field("imperial"), do: "feelslikeF"
  defp feelslike_field(_), do: "feelslikeC"
  defp wind_speed_field("imperial"), do: "windSpeedMPH"
  defp wind_speed_field(_), do: "windSpeedKPH"
  defp wind_gust_field("imperial"), do: "windGustMPH"
  defp wind_gust_field(_), do: "windGustKPH"
  defp dew_point_field("imperial"), do: "dewpointF"
  defp dew_point_field(_), do: "dewpointC"
  defp visibility_field("imperial"), do: "visibilityMI"
  defp visibility_field(_), do: "visibilityKM"

  # Classifies Xweather's `weather` text (e.g. "Partly Cloudy with Isolated
  # Storms", "Mostly Sunny") into the provider-neutral tokens documented in
  # FamilyDashboard.Weather.Provider.
  #
  # This reads the text field rather than the `icon` filename deliberately:
  # verified live against the real API, Xweather's icon names turned out to be
  # inconsistent/undocumented compound forms with no confirmable table (e.g.
  # "fairn.png" for a nighttime "Mostly Clear", "pcloudyt.png" for "Partly
  # Cloudy with Isolated Storms") — guessing that scheme would silently
  # misclassify. The `weather` text, by contrast, is a small, consistent
  # English vocabulary across every endpoint, so substring matching on it is
  # both simpler and more reliable. Checked most-severe-condition first, so a
  # compound description like "storms" wins over the "cloudy" in the same
  # phrase — the more urgent condition is what a glance-icon should show.
  #
  # The severe/exotic checks (tornado, hurricane, blizzard, ice storm) MUST
  # come before the generic "storm" check below: phrases like "Tropical Storm"
  # and "Winter Storm" contain the substring "storm" and would otherwise
  # misclassify as a plain thunderstorm.
  #
  # Keyword coverage here is driven by Xweather's documented, exhaustive
  # "weather type" code table (the third segment of `weatherCoded`/
  # `weatherPrimaryCoded`: A/BD/BN/BR/BS/BY/F/FC/FR/H/IC/IF/IP/K/L/R/RW/RS/SI/
  # WM/S/SW/T/TO/UP/VA/WP/ZF/ZL/ZR/ZY — see
  # https://www.xweather.com/docs/weather-api/reference/weather-codes) — every
  # keyword below corresponds to that table's English description, so the
  # closed set of *conditions* Xweather can report is covered even though this
  # matches on the `weather` text rather than parsing the code itself. Parsing
  # the code was deliberately skipped: it's inconsistently present/typed across
  # endpoints (empty array on /forecasts, a string on /conditions, in live
  # testing), so a text fallback would still be required either way — one path
  # is simpler than two. `UP` ("Unknown precipitation") has no keyword; it
  # correctly falls through to `nil` rather than guessing.
  defp icon(nil), do: nil

  defp icon(text) when is_binary(text) do
    t = String.downcase(text)

    cond do
      String.contains?(t, "tornado") or String.contains?(t, "funnel cloud") or
          String.contains?(t, "waterspout") ->
        "tornado"

      String.contains?(t, "hurricane") or String.contains?(t, "tropical storm") or
        String.contains?(t, "tropical depression") or String.contains?(t, "typhoon") ->
        "hurricane"

      String.contains?(t, "blizzard") or String.contains?(t, "winter storm") ->
        "blizzard"

      String.contains?(t, "freezing rain") or String.contains?(t, "freezing drizzle") or
        String.contains?(t, "freezing spray") or String.contains?(t, "ice storm") or
          String.contains?(t, "icy") ->
        "ice_storm"

      String.contains?(t, "storm") or String.contains?(t, "hail") ->
        "thunderstorm"

      String.contains?(t, "snow") or String.contains?(t, "flurr") or
        String.contains?(t, "sleet") or String.contains?(t, "wintry") or
        String.contains?(t, "ice pellet") or String.contains?(t, "pellet") ->
        "snow"

      String.contains?(t, "shower") ->
        "showers"

      String.contains?(t, "rain") or String.contains?(t, "drizzle") ->
        "rain"

      String.contains?(t, "fog") or String.contains?(t, "haze") or
        String.contains?(t, "smoke") or String.contains?(t, "dust") or
        String.contains?(t, "mist") or String.contains?(t, "sand") or
        String.contains?(t, "volcanic") or String.contains?(t, "ash") or
          String.contains?(t, "spray") ->
        "fog"

      String.contains?(t, "partly cloudy") ->
        "partly_cloudy"

      String.contains?(t, "cloud") or String.contains?(t, "overcast") ->
        "cloudy"

      String.contains?(t, "sunny") or String.contains?(t, "clear") or
        String.contains?(t, "fair") or String.contains?(t, "frost") ->
        "clear"

      true ->
        nil
    end
  end

  defp icon(_), do: nil

  defp parse_timestamp(unix) when is_integer(unix), do: DateTime.from_unix!(unix)
  defp parse_timestamp(_), do: nil

  defp parse_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil

  # Xweather's `pop` is already a 0-100 percentage; OWM's is a 0.0-1.0 fraction,
  # and the shared render code (dashboard_live.ex's pop_pct/1) multiplies by
  # 100 assuming that fraction convention — passing Xweather's value through
  # unconverted displayed e.g. 79% as 7900%. Normalize to the same fraction
  # OWM uses so the two providers agree on what `pop` means.
  defp pop_fraction(nil), do: nil
  defp pop_fraction(pct) when is_number(pct), do: pct / 100

  # Several of Xweather's fields (visibility in particular, e.g. "9.942" mi)
  # come back as floats where the corresponding resource attribute is an
  # :integer (OWM's equivalents were always whole numbers) — Ash's strict
  # typing rejects a float for an :integer attribute outright, so round at
  # the adapter boundary rather than letting that surface as a write failure.
  defp round_int(nil), do: nil
  defp round_int(n) when is_number(n), do: round(n)
  defp round_int(_), do: nil

  defp client_id, do: Application.get_env(:family_dashboard, :xweather_client_id)
  defp client_secret, do: Application.get_env(:family_dashboard, :xweather_client_secret)
end
