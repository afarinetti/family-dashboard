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
          "pop" => 0.1 * i,
          "weather" => [%{"icon" => "01d"}]
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
          "weather" => if(rem(i, 2) == 0, do: nil, else: [%{"icon" => "10d"}])
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

  describe "fetch/4" do
    test "returns current conditions" do
      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      assert r.temp == 71.2
      assert r.feels_like == 69.8
      assert r.condition == "overcast clouds"
      assert r.icon == "04d"
      assert %DateTime{} = r.observed_at
    end

    test "includes the next 8 forecast hours" do
      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      hourly = r.forecast["hourly"]
      assert length(hourly) == 8
      assert List.first(hourly)["temp"] == 70.0
      assert List.first(hourly)["icon"] == "01d"
      assert is_number(List.first(hourly)["pop"])
    end

    test "includes the next 7 forecast days and today's high/low" do
      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: stub_plug())

      days = r.forecast["days"]
      assert length(days) == 7
      # today's high/low mirrors the first daily entry
      assert r.high == 80.0
      assert r.low == 60.0
      # null daily "weather" yields a nil icon, non-null yields the icon
      assert List.first(days)["icon"] == nil
      assert Enum.at(days, 1)["icon"] == "10d"
    end

    test "current conditions still return when forecast calls fail (best-effort)" do
      plug = fn conn ->
        case conn.request_path do
          "/data/4.0/onecall/current" -> Req.Test.json(conn, @current)
          _ -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert {:ok, r} = Weather.fetch(41.88, -87.63, "imperial", plug: plug)
      assert r.temp == 71.2
      assert r.forecast["hourly"] == []
      assert r.forecast["days"] == []
      assert is_nil(r.high)
    end

    test "returns an error when the current call is unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               Weather.fetch(41.88, -87.63, "imperial", plug: plug)
    end
  end
end
