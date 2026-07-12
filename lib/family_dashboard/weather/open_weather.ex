defmodule FamilyDashboard.Weather.OpenWeather do
  @moduledoc """
  Facade around the OpenWeatherMap **One Call API 4.0**. Each refresh makes three
  independent calls:

    * `/data/4.0/onecall/current`      — current conditions (authoritative)
    * `/data/4.0/onecall/timeline/1h`  — hourly forecast (next 8 hours)
    * `/data/4.0/onecall/timeline/1day`— daily forecast (next 7 days)

  Implements `FamilyDashboard.Weather.Provider` — see that module for the
  normalized shape this adapter must return. The hourly and daily calls are
  best-effort — a slow/failing forecast endpoint drops that section rather
  than failing the whole refresh.

  Note: One Call API 4.0 requires the "One Call by Call" subscription on the
  account tied to `WEATHER_API_KEY`.

  Known limitation (why Xweather is now the default provider): `/timeline/1day`
  reliably returns `"weather": null` for every day on every account/location we
  tested (Houston, LA, Houston, NYC, Chicago, Miami, Seattle, Denver, Tokyo all
  showed 0/10 days populated) — so daily icon/condition/summary are effectively
  never available from OWM. `Sync.patch_today_weather/2` papers over this for
  *today* by borrowing from the hourly endpoint; days 1-6 stay blank.
  """

  @behaviour FamilyDashboard.Weather.Provider

  @base_url "https://api.openweathermap.org"
  @current_path "/data/4.0/onecall/current"
  @hourly_path "/data/4.0/onecall/timeline/1h"
  @daily_path "/data/4.0/onecall/timeline/1day"

  @hours 8
  @days 7
  # Timeouts bound how long a slow timeline can stall the worker. The daily
  # endpoint is genuinely slow (OWM often takes ~15-21s to return populated data),
  # so it gets a much longer budget than the fast hourly call.
  @hourly_timeout 8_000
  # The daily endpoint is intermittent (fast when it works, hangs otherwise);
  # cap each attempt and try twice, so the worst case is bounded (~2 x 15s).
  @daily_timeout 15_000
  @daily_attempts 2

  @impl true
  def credentials_configured?, do: not is_nil(api_key())

  @doc """
  Fetches current conditions + the hourly forecast for `lat`/`lon`. The daily
  forecast is fetched separately (`fetch_daily/4`) because that endpoint is slow
  and flaky. Extra `opts` are forwarded to `Req.get/2` (e.g. a `:plug` stub in
  tests). Returns `{:ok, reading_attrs}` (reading scalars + a `:hourly` list, no
  daily fields) or `{:error, reason}`.
  """
  @impl true
  @spec fetch_current_and_hourly(number(), number(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_current_and_hourly(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts) do
      hourly = best_effort(@hourly_path, params, opts, @hourly_timeout)
      {:ok, normalize_current(current, hourly)}
    end
  end

  @doc """
  Fetches just the 7-day forecast. Retries a couple times because OWM's daily
  endpoint intermittently hangs or returns an empty `data` array. Returns
  `{:ok, days}` (a non-empty list of day attr maps shaped for
  `FamilyDashboard.WeatherDaily`) or `{:error, :no_daily}`.
  """
  @impl true
  @spec fetch_daily(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_daily}
  def fetch_daily(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    case best_effort_daily(params, opts, @daily_attempts) do
      %{"data" => [_ | _]} = body -> {:ok, daily_summary(body)}
      _ -> {:error, :no_daily}
    end
  end

  @doc """
  Not implemented — hurricane/tropical alert data lives in a separate feed
  this adapter doesn't fetch (see `icon/1` below). Always returns
  `{:error, :no_alerts}` so `Sync` treats this provider as having no alerts
  rather than raising `UndefinedFunctionError`.
  """
  @impl true
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(_lat, _lon, _units, _opts \\ []), do: {:error, :no_alerts}

  defp best_effort_daily(_params, _opts, 0), do: %{}

  defp best_effort_daily(params, opts, attempts) do
    body = best_effort(@daily_path, params, opts, @daily_timeout)

    if (body["data"] || []) == [] do
      best_effort_daily(params, opts, attempts - 1)
    else
      body
    end
  end

  defp get(path, params, opts) do
    # `compressed: false` is REQUIRED: OWM's One Call timeline endpoints hang/return
    # empty when gzip is requested (curl works because it doesn't ask for gzip).
    # No per-request retry — Oban owns retries at the job level.
    base = [
      base_url: @base_url,
      url: path,
      params: params,
      retry: false,
      compressed: false
    ]

    case Req.get(Keyword.merge(base, opts)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp best_effort(path, params, opts, timeout) do
    opts = Keyword.put_new(opts, :receive_timeout, timeout)

    case get(path, params, opts) do
      {:ok, body} -> body
      {:error, _} -> %{}
    end
  end

  defp normalize_current(current, hourly) do
    obs = (current["data"] || []) |> List.first() || %{}
    weather = (obs["weather"] || []) |> List.first() || %{}
    now = obs["dt"] || 0

    %{
      observed_at: unix_to_datetime(obs["dt"]),
      temp: obs["temp"],
      feels_like: obs["feels_like"],
      condition: weather["description"] || weather["main"],
      icon: icon(weather),
      humidity: obs["humidity"],
      pressure: obs["pressure"],
      dew_point: obs["dew_point"],
      uvi: obs["uvi"],
      clouds: obs["clouds"],
      visibility: obs["visibility"],
      wind_speed: obs["wind_speed"],
      wind_deg: obs["wind_deg"],
      wind_gust: obs["wind_gust"],
      sunrise: unix_to_datetime(obs["sunrise"]),
      sunset: unix_to_datetime(obs["sunset"]),
      # 4.0 current returns no place name; the dashboard uses Setting.city_label.
      location_label: nil,
      hourly: hourly_summary(hourly, now)
    }
  end

  # Next @hours forecast hours from now.
  defp hourly_summary(hourly, now) do
    (hourly["data"] || [])
    |> Enum.filter(&((&1["dt"] || 0) >= now))
    |> Enum.take(@hours)
    |> Enum.map(fn hour ->
      weather = (hour["weather"] || []) |> List.first()

      %{
        forecast_time: unix_to_datetime(hour["dt"]),
        temp: hour["temp"],
        feels_like: hour["feels_like"],
        pop: hour["pop"],
        humidity: hour["humidity"],
        wind_speed: hour["wind_speed"],
        icon: icon(weather),
        condition: condition(weather)
      }
    end)
  end

  # The first @days forecast days (the endpoint returns forward-looking data from
  # now). Daily `temp` is a min/max object; `weather` may be null → nil icon/condition.
  defp daily_summary(body) do
    (body["data"] || [])
    |> Enum.take(@days)
    |> Enum.map(fn day ->
      temp = day["temp"] || %{}
      weather = (day["weather"] || []) |> List.first()

      %{
        forecast_date: unix_to_datetime(day["dt"]),
        high: temp["max"],
        low: temp["min"],
        pop: day["pop"],
        summary: day["summary"],
        humidity: day["humidity"],
        wind_speed: day["wind_speed"],
        sunrise: unix_to_datetime(day["sunrise"]),
        sunset: unix_to_datetime(day["sunset"]),
        icon: icon(weather),
        condition: condition(weather)
      }
    end)
  end

  # OWM's numeric condition `id` is documented as an exhaustive, closed table
  # (https://openweathermap.org/weather-conditions) — every id below is every
  # id OWM defines. Mapping by `id` (rather than the compact 9-bucket `icon`
  # vocabulary) is what lets tornado (781), squalls (771), and freezing rain
  # (511) come out distinct instead of all collapsing into their nearest
  # neighbor (thunderstorm/fog/snow respectively) — that collapsing was an
  # actual misclassification the icon-only approach had, not just missing
  # nice-to-have detail.
  @id_tokens %{
    # Thunderstorm
    200 => "thunderstorm",
    201 => "thunderstorm",
    202 => "thunderstorm",
    210 => "thunderstorm",
    211 => "thunderstorm",
    212 => "thunderstorm",
    221 => "thunderstorm",
    230 => "thunderstorm",
    231 => "thunderstorm",
    232 => "thunderstorm",
    # Drizzle (kept in the "rain" bucket rather than splitting further)
    300 => "rain",
    301 => "rain",
    302 => "rain",
    310 => "rain",
    311 => "rain",
    312 => "rain",
    313 => "rain",
    314 => "rain",
    321 => "rain",
    # Rain
    500 => "rain",
    501 => "rain",
    502 => "rain",
    503 => "rain",
    504 => "rain",
    511 => "ice_storm",
    520 => "showers",
    521 => "showers",
    522 => "showers",
    531 => "showers",
    # Snow
    600 => "snow",
    601 => "snow",
    602 => "snow",
    611 => "snow",
    612 => "snow",
    613 => "snow",
    615 => "snow",
    616 => "snow",
    620 => "snow",
    621 => "snow",
    622 => "snow",
    # Atmosphere
    701 => "fog",
    711 => "fog",
    721 => "fog",
    731 => "fog",
    741 => "fog",
    751 => "fog",
    761 => "fog",
    762 => "fog",
    # Severe wind gusts, often preceding/accompanying a storm — no dedicated
    # token, "thunderstorm" is the closest severe bucket.
    771 => "thunderstorm",
    781 => "tornado",
    # Clear / clouds
    800 => "clear",
    801 => "partly_cloudy",
    802 => "cloudy",
    803 => "cloudy",
    804 => "cloudy"
  }

  # Maps OWM's weather data to the provider-neutral tokens documented in
  # FamilyDashboard.Weather.Provider, so stored rows don't care which provider
  # produced them. Prefers the exhaustive `id` table above; falls back to the
  # compact `icon` code (e.g. "01d"/"01n") when `id` is absent — real OWM
  # responses always include both, but the fallback keeps this adapter working
  # against any input that only has one.
  #
  # There's no OWM condition id for hurricane/tropical storm (that data lives
  # in a separate alerts feed this adapter doesn't fetch), so unlike the
  # Xweather adapter, this one can't reliably tell a hurricane apart from
  # severe rain — left as ordinary "rain"/"showers" rather than guessing.
  defp icon(nil), do: nil

  defp icon(%{"id" => id} = weather) do
    case Map.fetch(@id_tokens, id) do
      {:ok, token} -> token
      :error -> icon_from_code(weather["icon"])
    end
  end

  defp icon(%{"icon" => icon}), do: icon_from_code(icon)
  defp icon(_), do: nil

  defp icon_from_code(icon) when is_binary(icon) do
    case String.slice(icon, 0, 2) do
      "01" -> "clear"
      "02" -> "partly_cloudy"
      "03" -> "cloudy"
      "04" -> "cloudy"
      "09" -> "rain"
      "10" -> "showers"
      "11" -> "thunderstorm"
      "13" -> "snow"
      "50" -> "fog"
      _ -> nil
    end
  end

  defp icon_from_code(_), do: nil

  defp condition(nil), do: nil
  defp condition(%{"description" => d}), do: d
  defp condition(%{"main" => m}), do: m
  defp condition(_), do: nil

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  defp api_key, do: Application.get_env(:family_dashboard, :openweather_api_key)
end
