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
  # Forecast calls get a bounded timeout so a slow timeline can't stall the worker.
  @forecast_timeout 8_000

  @doc """
  Fetches current conditions plus the hourly and daily forecast for `lat`/`lon`
  in the given `units`. Extra `opts` are forwarded to `Req.get/2` (e.g. a `:plug`
  stub in tests). Returns `{:ok, reading_attrs}` or `{:error, reason}` (only the
  current call can fail the whole fetch).
  """
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts) do
      hourly = best_effort(@hourly_path, params, opts)
      daily = best_effort(@daily_path, params, opts)
      {:ok, normalize(current, hourly, daily)}
    end
  end

  defp get(path, params, opts) do
    # No per-request retry — Oban owns retries at the job level.
    req_opts = Keyword.merge([base_url: @base_url, url: path, params: params, retry: false], opts)

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp best_effort(path, params, opts) do
    opts = Keyword.put_new(opts, :receive_timeout, @forecast_timeout)

    case get(path, params, opts) do
      {:ok, body} -> body
      {:error, _} -> %{}
    end
  end

  defp normalize(current, hourly, daily) do
    obs = (current["data"] || []) |> List.first() || %{}
    weather = (obs["weather"] || []) |> List.first() || %{}
    now = obs["dt"] || 0

    days = daily_summary(daily, now)
    today = List.first(days) || %{}

    %{
      observed_at: unix_to_datetime(obs["dt"]),
      temp: obs["temp"],
      feels_like: obs["feels_like"],
      condition: weather["description"] || weather["main"],
      icon: weather["icon"],
      high: today["high"],
      low: today["low"],
      # 4.0 current returns no place name; the dashboard uses Setting.city_label.
      location_label: nil,
      forecast: %{
        "hourly" => hourly_summary(hourly, now),
        "days" => days
      }
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

  # Next @days forecast days including today (daily `temp` is a min/max object;
  # `weather` may be null, so `icon` can be nil).
  defp daily_summary(daily, now) do
    today_start = now - 43_200

    (daily["data"] || [])
    |> Enum.filter(&((&1["dt"] || 0) >= today_start))
    |> Enum.take(@days)
    |> Enum.map(fn day ->
      temp = day["temp"] || %{}

      %{
        "dt" => day["dt"],
        "high" => temp["max"],
        "low" => temp["min"],
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
