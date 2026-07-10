defmodule FamilyDashboard.WeatherTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.Weather

  @current %{
    "dt" => 1_783_000_000,
    "name" => "Chicago",
    "main" => %{"temp" => 71.2, "feels_like" => 69.8, "temp_min" => 66.0, "temp_max" => 75.0},
    "weather" => [%{"main" => "Clouds", "description" => "overcast clouds", "icon" => "04d"}]
  }

  # Two 3-hour periods on 2026-07-11, one on 2026-07-12.
  @forecast %{
    "city" => %{"name" => "Chicago"},
    "list" => [
      %{
        "dt" => 1_783_000_000,
        "main" => %{"temp_min" => 66.0, "temp_max" => 75.0},
        "weather" => [%{"icon" => "01d"}]
      },
      %{
        "dt" => 1_783_010_800,
        "main" => %{"temp_min" => 64.0, "temp_max" => 79.0},
        "weather" => [%{"icon" => "10d"}]
      },
      %{
        "dt" => 1_783_097_200,
        "main" => %{"temp_min" => 60.0, "temp_max" => 70.0},
        "weather" => [%{"icon" => "01d"}]
      }
    ]
  }

  defp stub_plug do
    fn conn ->
      case conn.request_path do
        "/data/2.5/weather" -> Req.Test.json(conn, @current)
        "/data/2.5/forecast" -> Req.Test.json(conn, @forecast)
      end
    end
  end

  describe "fetch/4" do
    test "returns a normalized reading with current conditions" do
      assert {:ok, reading} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert reading.temp == 71.2
      assert reading.feels_like == 69.8
      assert reading.high == 75.0
      assert reading.low == 66.0
      assert reading.condition == "overcast clouds"
      assert reading.icon == "04d"
      assert reading.location_label == "Chicago"
      assert %DateTime{} = reading.observed_at
    end

    test "aggregates the 3-hour forecast into per-day high/low" do
      assert {:ok, reading} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert [day1, day2] = reading.forecast["days"]

      # 2026-07-11 spans two periods: high = max(75, 79), low = min(66, 64).
      assert day1["high"] == 79.0
      assert day1["low"] == 64.0
      assert day2["high"] == 70.0
      assert day2["low"] == 60.0
    end

    test "returns an error tuple on a non-200 response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               Weather.fetch(41.88, -87.63, "imperial", plug: plug)
    end
  end
end
