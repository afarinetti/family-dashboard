defmodule FamilyDashboard.Weather do
  @moduledoc """
  Facade around the OpenWeatherMap **One Call API 4.0**
  (`/data/4.0/onecall/current` for current conditions and
  `/data/4.0/onecall/timeline/1day` for the daily min/max).

  `fetch/4` returns a map shaped for `FamilyDashboard.WeatherReading`'s create
  action. The rest of the app depends only on this module, never on the HTTP
  shape of OpenWeatherMap.

  Note: One Call API 4.0 requires the "One Call by Call" subscription on the
  OpenWeatherMap account tied to `WEATHER_API_KEY` (1,000 calls/day free tier).
  """

  @base_url "https://api.openweathermap.org"
  @current_path "/data/4.0/onecall/current"
  @daily_path "/data/4.0/onecall/timeline/1day"

  @doc """
  Fetches current conditions (+ today's high/low) for `lat`/`lon` in the given
  `units` ("imperial", "metric", or "standard"). Extra `opts` are forwarded to
  `Req.get/2` (e.g. a `:plug` stub in tests). Returns `{:ok, reading_attrs}` or
  `{:error, reason}`.

  The current-conditions call is authoritative; the daily call is best-effort,
  so a temporarily-unavailable forecast only drops high/low, not the whole read.
  """
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts) do
      daily =
        case get(@daily_path, params, opts) do
          {:ok, body} -> body
          {:error, _} -> %{}
        end

      {:ok, normalize(current, daily)}
    end
  end

  defp get(path, params, opts) do
    # No per-request retry: Oban owns retries at the job level, and the daily
    # call is best-effort, so retrying a 500 would only stall the worker.
    req_opts = Keyword.merge([base_url: @base_url, url: path, params: params, retry: false], opts)

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # One Call 4.0 wraps the current observation in a single-element `data` array.
  defp normalize(current, daily) do
    obs = current |> Map.get("data", []) |> List.first() || %{}
    weather = obs |> Map.get("weather", []) |> List.first() || %{}
    days = daily_summary(daily)
    today = List.first(days) || %{}

    %{
      observed_at: unix_to_datetime(obs["dt"]),
      temp: obs["temp"],
      feels_like: obs["feels_like"],
      condition: weather["description"] || weather["main"],
      icon: weather["icon"],
      high: today["high"],
      low: today["low"],
      # 4.0 current does not return a place name; the dashboard uses Setting.city_label.
      location_label: nil,
      forecast: %{"days" => days}
    }
  end

  # The `timeline/1day` `data` array holds per-day entries with temp.min/max.
  defp daily_summary(daily) do
    daily
    |> Map.get("data", [])
    |> Enum.map(fn day ->
      temp = day["temp"] || %{}

      %{
        "dt" => day["dt"],
        "high" => temp["max"],
        "low" => temp["min"],
        "icon" => day |> Map.get("weather", []) |> List.first() |> icon()
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
