defmodule FamilyDashboard.WeatherTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.Weather

  # One Call API 4.0 shapes: current obs wrapped in a `data` array; daily
  # timeline entries carry temp.min/max.
  @current %{
    "lat" => 41.88,
    "lon" => -87.63,
    "data" => [
      %{
        "dt" => 1_783_000_000,
        "temp" => 71.2,
        "feels_like" => 69.8,
        "weather" => [%{"description" => "overcast clouds", "icon" => "04d"}]
      }
    ]
  }

  # Mirrors the real One Call 4.0 daily shape: `temp` is a rich object and
  # `weather` is sent as an explicit null (this exact shape crashed a naive parse).
  @daily %{
    "data" => [
      %{
        "dt" => 1_783_000_000,
        "temp" => %{"min" => 66.0, "max" => 75.0, "day" => 72.0, "night" => 68.0},
        "weather" => nil
      },
      %{
        "dt" => 1_783_086_400,
        "temp" => %{"min" => 60.0, "max" => 70.0, "day" => 66.0, "night" => 62.0},
        "weather" => [%{"icon" => "10d"}]
      }
    ]
  }

  defp stub_plug do
    fn conn ->
      case conn.request_path do
        "/data/4.0/onecall/current" -> Req.Test.json(conn, @current)
        "/data/4.0/onecall/timeline/1day" -> Req.Test.json(conn, @daily)
      end
    end
  end

  describe "fetch/4" do
    test "returns a normalized reading with current conditions" do
      assert {:ok, reading} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert reading.temp == 71.2
      assert reading.feels_like == 69.8
      assert reading.condition == "overcast clouds"
      assert reading.icon == "04d"
      assert %DateTime{} = reading.observed_at
    end

    test "takes today's high/low from the daily timeline" do
      assert {:ok, reading} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert reading.high == 75.0
      assert reading.low == 66.0

      assert [day1, day2] = reading.forecast["days"]
      assert day1["high"] == 75.0 and day1["low"] == 66.0
      assert day2["high"] == 70.0 and day2["low"] == 60.0
    end

    test "still returns current conditions when the daily call fails" do
      plug = fn conn ->
        case conn.request_path do
          "/data/4.0/onecall/current" -> Req.Test.json(conn, @current)
          "/data/4.0/onecall/timeline/1day" -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert {:ok, reading} = Weather.fetch(41.88, -87.63, "imperial", plug: plug)
      assert reading.temp == 71.2
      assert is_nil(reading.high)
      assert reading.forecast["days"] == []
    end

    test "returns an error tuple when the current call is unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               Weather.fetch(41.88, -87.63, "imperial", plug: plug)
    end
  end
end
