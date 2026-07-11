defmodule FamilyDashboard.WeatherTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.Weather

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

  describe "fetch/4 (current + hourly)" do
    test "returns current conditions, including fields previously discarded" do
      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert r.temp == 71.2
      assert r.feels_like == 69.8
      assert r.condition == "overcast clouds"
      assert r.icon == "04d"
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
      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(r.hourly) == 8
      first = List.first(r.hourly)
      assert first.temp == 70.0
      assert first.icon == "01d"
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

      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: plug)
      assert r.temp == 71.2
      assert r.hourly == []
    end

    test "returns an error when the current call is unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               Weather.fetch(41.88, -87.63, "imperial", plug: plug)
    end
  end

  describe "fetch_daily/4" do
    test "returns the next 7 days as structured attrs" do
      assert {:ok, days} = Weather.fetch_daily(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(days) == 7
      first = List.first(days)
      assert first.high == 80.0
      assert first.low == 60.0
      assert is_number(first.pop)
      assert first.summary == "Mostly sunny"
      assert %DateTime{} = first.forecast_date
      # null daily "weather" yields a nil icon/condition, a non-null one yields values
      assert first.icon == nil
      assert Enum.at(days, 1).icon == "10d"
      assert Enum.at(days, 1).condition == "light rain"
    end

    test "returns {:error, :no_daily} when the endpoint returns empty data" do
      plug = fn conn -> Req.Test.json(conn, %{"data" => []}) end

      assert {:error, :no_daily} = Weather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
    end
  end
end
