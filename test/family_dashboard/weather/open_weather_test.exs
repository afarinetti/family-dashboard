defmodule FamilyDashboard.Weather.OpenWeatherTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.Weather.OpenWeather

  # All forecast times are relative to the current observation's dt, so filtering
  # "future" entries is deterministic and independent of the wall clock.
  @now 1_783_000_000

  @current %{
    "data" => [
      %{
        "dt" => @now,
        "temp" => 71.2,
        "feels_like" => 69.8,
        "humidity" => 55,
        "pressure" => 1013,
        "dew_point" => 60.1,
        "uvi" => 3.2,
        "clouds" => 75,
        "visibility" => 10_000,
        "wind_speed" => 8.5,
        "wind_deg" => 210,
        "wind_gust" => 12.0,
        "sunrise" => @now - 3600,
        "sunset" => @now + 36_000,
        "weather" => [%{"description" => "overcast clouds", "icon" => "04d"}]
      }
    ]
  }

  # 12 hourly entries from now; hourly `temp` is a plain number, `pop` present.
  @hourly %{
    "data" =>
      for i <- 0..11 do
        %{
          "dt" => @now + i * 3600,
          "temp" => 70.0 + i,
          "feels_like" => 68.0 + i,
          "humidity" => 50 + i,
          "wind_speed" => 5.0 + i,
          "pop" => 0.1 * i,
          "weather" => [%{"icon" => "01d", "description" => "clear sky"}]
        }
      end
  }

  # 9 daily entries; daily `temp` is a min/max object and `weather` may be null.
  @daily %{
    "data" =>
      for i <- 0..8 do
        %{
          "dt" => @now + i * 86_400,
          "temp" => %{"min" => 60.0 + i, "max" => 80.0 + i, "day" => 72.0},
          "pop" => 0.1 * i,
          "summary" => "Mostly sunny",
          "humidity" => 45 + i,
          "wind_speed" => 6.0 + i,
          "sunrise" => @now + i * 86_400 - 3600,
          "sunset" => @now + i * 86_400 + 36_000,
          "weather" =>
            if(rem(i, 2) == 0, do: nil, else: [%{"icon" => "10d", "description" => "light rain"}])
        }
      end
  }

  defp stub_plug do
    fn conn ->
      case conn.request_path do
        "/data/4.0/onecall/current" -> Req.Test.json(conn, @current)
        "/data/4.0/onecall/timeline/1h" -> Req.Test.json(conn, @hourly)
        "/data/4.0/onecall/timeline/1day" -> Req.Test.json(conn, @daily)
      end
    end
  end

  describe "fetch_current_and_hourly/4" do
    test "returns current conditions, including fields previously discarded" do
      assert {:ok, r} =
               OpenWeather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: stub_plug())

      assert r.temp == 71.2
      assert r.feels_like == 69.8
      assert r.condition == "overcast clouds"
      # OWM icon "04d" (broken clouds) normalizes to the neutral "cloudy" token.
      assert r.icon == "cloudy"
      assert %DateTime{} = r.observed_at
      assert r.humidity == 55
      assert r.pressure == 1013
      assert r.dew_point == 60.1
      assert r.uvi == 3.2
      assert r.clouds == 75
      assert r.visibility == 10_000
      assert r.wind_speed == 8.5
      assert r.wind_deg == 210
      assert r.wind_gust == 12.0
      assert %DateTime{} = r.sunrise
      assert %DateTime{} = r.sunset
    end

    test "includes the next 8 forecast hours as structured attrs" do
      assert {:ok, r} =
               OpenWeather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(r.hourly) == 8
      first = List.first(r.hourly)
      assert first.temp == 70.0
      assert first.icon == "clear"
      assert first.condition == "clear sky"
      assert is_number(first.pop)
      assert is_number(first.humidity)
      assert is_number(first.wind_speed)
      assert %DateTime{} = first.forecast_time
    end

    test "current conditions still return when the hourly call fails (best-effort)" do
      plug = fn conn ->
        case conn.request_path do
          "/data/4.0/onecall/current" -> Req.Test.json(conn, @current)
          _ -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert {:ok, r} =
               OpenWeather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)

      assert r.temp == 71.2
      assert r.hourly == []
    end

    test "returns an error when the current call is unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               OpenWeather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)
    end
  end

  describe "fetch_daily/4" do
    test "returns the next 7 days as structured attrs" do
      assert {:ok, days} = OpenWeather.fetch_daily(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(days) == 7
      first = List.first(days)
      assert first.high == 80.0
      assert first.low == 60.0
      assert is_number(first.pop)
      assert first.summary == "Mostly sunny"
      assert %DateTime{} = first.forecast_date
      # null daily "weather" yields a nil icon/condition, a non-null one yields
      # values normalized to the neutral token vocabulary ("10d" -> "showers").
      assert first.icon == nil
      assert Enum.at(days, 1).icon == "showers"
      assert Enum.at(days, 1).condition == "light rain"
    end

    test "returns {:error, :no_daily} when the endpoint returns empty data" do
      plug = fn conn -> Req.Test.json(conn, %{"data" => []}) end

      assert {:error, :no_daily} = OpenWeather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
    end

    # Every condition id OWM documents (https://openweathermap.org/weather-conditions),
    # exhaustively, not just the severe ones — de-conflating by id (rather than
    # the compact 9-bucket icon code) is what fixes real misclassifications:
    # 781 (tornado) and 771 (squalls) both share icon "50d" with plain fog, and
    # 511 (freezing rain) shares icon "13d" with ordinary snow.
    @id_to_token %{
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
      # Drizzle
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
      771 => "thunderstorm",
      781 => "tornado",
      # Clear / clouds
      800 => "clear",
      801 => "partly_cloudy",
      802 => "cloudy",
      803 => "cloudy",
      804 => "cloudy"
    }

    for {id, expected_token} <- @id_to_token do
      test "classifies condition id #{id} as #{inspect(expected_token)}" do
        body = %{
          "data" => [
            %{
              "dt" => 1_783_000_000,
              "temp" => %{"min" => 60.0, "max" => 80.0},
              "weather" => [%{"id" => unquote(id), "icon" => "01d", "description" => "n/a"}]
            }
          ]
        }

        plug = fn conn -> Req.Test.json(conn, body) end
        assert {:ok, [day]} = OpenWeather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
        assert day.icon == unquote(expected_token)
      end
    end

    test "falls back to the icon code when id is absent" do
      # The existing fixtures throughout this file only carry "icon", no "id"
      # (mirroring how this adapter behaved before the id table existed) —
      # this proves that fallback path still works standalone.
      body = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => %{"min" => 60.0, "max" => 80.0},
            "weather" => [%{"icon" => "13d", "description" => "snow"}]
          }
        ]
      }

      plug = fn conn -> Req.Test.json(conn, body) end
      assert {:ok, [day]} = OpenWeather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
      assert day.icon == "snow"
    end
  end
end
