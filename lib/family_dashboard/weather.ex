defmodule FamilyDashboard.Weather do
  @moduledoc """
  Facade around the OpenWeatherMap **One Call API 4.0**. Each refresh makes three
  independent calls:

    * `/data/4.0/onecall/current`      — current conditions (authoritative)
    * `/data/4.0/onecall/timeline/1h`  — hourly forecast (next 8 hours)
    * `/data/4.0/onecall/timeline/1day`— daily forecast (next 7 days)

  `fetch/4` returns a map shaped for `FamilyDashboard.WeatherReading`. The hourly
  and daily calls are best-effort — a slow/failing forecast endpoint drops that
  section rather than failing the whole refresh. The rest of the app depends only
  on this module, never on OpenWeatherMap's HTTP shape.

  Note: One Call API 4.0 requires the "One Call by Call" subscription on the
  account tied to `WEATHER_API_KEY`.
  """

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

  @doc """
  Fetches current conditions + the hourly forecast for `lat`/`lon`. The daily
  forecast is fetched separately (`fetch_daily/4`) because that endpoint is slow
  and flaky. Extra `opts` are forwarded to `Req.get/2` (e.g. a `:plug` stub in
  tests). Returns `{:ok, reading_attrs}` (no daily fields) or `{:error, reason}`.
  """
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts) do
      hourly = best_effort(@hourly_path, params, opts, @hourly_timeout)
      {:ok, normalize_current(current, hourly)}
    end
  end

  @doc """
  Fetches just the 7-day forecast. Retries a couple times because OWM's daily
  endpoint intermittently hangs or returns an empty `data` array. Returns
  `{:ok, days}` (a non-empty list of day summaries) or `{:error, :no_daily}`.
  """
  @spec fetch_daily(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_daily}
  def fetch_daily(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    case best_effort_daily(params, opts, @daily_attempts) do
      %{"data" => [_ | _]} = body -> {:ok, daily_summary(body)}
      _ -> {:error, :no_daily}
    end
  end

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
      icon: weather["icon"],
      # high/low + days come from the separate daily job (see FamilyDashboard.Sync).
      high: nil,
      low: nil,
      # 4.0 current returns no place name; the dashboard uses Setting.city_label.
      location_label: nil,
      forecast: %{"hourly" => hourly_summary(hourly, now), "days" => []}
    }
  end

  # Next @hours forecast hours from now (hourly `temp` is a plain number).
  defp hourly_summary(hourly, now) do
    (hourly["data"] || [])
    |> Enum.filter(&((&1["dt"] || 0) >= now))
    |> Enum.take(@hours)
    |> Enum.map(fn hour ->
      %{
        "dt" => hour["dt"],
        "temp" => hour["temp"],
        "pop" => hour["pop"],
        "icon" => (hour["weather"] || []) |> List.first() |> icon()
      }
    end)
  end

  # The first @days forecast days (the endpoint returns forward-looking data from
  # now). Daily `temp` is a min/max object; `weather` may be null → `icon` nil.
  defp daily_summary(body) do
    (body["data"] || [])
    |> Enum.take(@days)
    |> Enum.map(fn day ->
      temp = day["temp"] || %{}

      %{
        "dt" => day["dt"],
        "high" => temp["max"],
        "low" => temp["min"],
        "pop" => day["pop"],
        "icon" => (day["weather"] || []) |> List.first() |> icon()
      }
    end)
  end

  defp icon(nil), do: nil
  defp icon(%{"icon" => icon}), do: icon
  defp icon(_), do: nil

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  defp api_key, do: Application.get_env(:family_dashboard, :openweather_api_key)
end
