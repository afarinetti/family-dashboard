defmodule FamilyDashboard.Weather do
  @moduledoc """
  Facade around the OpenWeatherMap free API (`/data/2.5/weather` for current
  conditions and `/data/2.5/forecast` for the 5-day/3-hour forecast).

  `fetch/4` returns a map shaped for `FamilyDashboard.WeatherReading`'s create
  action. The rest of the app depends only on this module, never on the HTTP
  shape of OpenWeatherMap.
  """

  @base_url "https://api.openweathermap.org"
  @current_path "/data/2.5/weather"
  @forecast_path "/data/2.5/forecast"

  @doc """
  Fetches current conditions + forecast for `lat`/`lon` in the given `units`
  ("imperial" or "metric"). Extra `opts` are forwarded to `Req.get/2`
  (e.g. a `:plug` stub in tests). Returns `{:ok, reading_attrs}` or `{:error, reason}`.
  """
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts),
         {:ok, forecast} <- get(@forecast_path, params, opts) do
      {:ok, normalize(current, forecast)}
    end
  end

  defp get(path, params, opts) do
    req_opts = Keyword.merge([base_url: @base_url, url: path, params: params], opts)

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(current, forecast) do
    main = current["main"] || %{}
    weather = current["weather"] |> List.wrap() |> List.first() || %{}

    %{
      observed_at: unix_to_datetime(current["dt"]),
      temp: main["temp"],
      feels_like: main["feels_like"],
      high: main["temp_max"],
      low: main["temp_min"],
      condition: weather["description"] || weather["main"],
      icon: weather["icon"],
      location_label: current["name"],
      forecast: %{"days" => daily_summary(forecast)}
    }
  end

  # Collapse the 3-hour forecast entries into per-day high/low + a representative icon.
  defp daily_summary(forecast) do
    forecast
    |> Map.get("list", [])
    |> Enum.group_by(fn entry -> entry["dt"] |> unix_to_datetime() |> DateTime.to_date() end)
    |> Enum.map(fn {date, entries} ->
      %{
        "date" => Date.to_iso8601(date),
        "high" => entries |> Enum.map(& &1["main"]["temp_max"]) |> Enum.max(),
        "low" => entries |> Enum.map(& &1["main"]["temp_min"]) |> Enum.min(),
        "icon" => entries |> List.first() |> get_in(["weather", Access.at(0), "icon"])
      }
    end)
    |> Enum.sort_by(& &1["date"])
    |> Enum.take(5)
  end

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  defp api_key, do: Application.get_env(:family_dashboard, :openweather_api_key)
end
