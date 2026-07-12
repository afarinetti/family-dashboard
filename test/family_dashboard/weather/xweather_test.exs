defmodule FamilyDashboard.Weather.XweatherTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.Weather.Xweather

  # All forecast times are relative to the current observation's timestamp, so
  # filtering "future" entries is deterministic and independent of the wall clock.
  @now 1_783_000_000

  @current %{
    "success" => true,
    "error" => nil,
    "response" => [
      %{
        "loc" => %{"lat" => 41.88, "long" => -87.63},
        "place" => %{"name" => "chicago", "state" => "il", "country" => "us"},
        "periods" => [
          %{
            "timestamp" => @now,
            "tempF" => 71.2,
            "feelslikeF" => 69.8,
            "humidity" => 55,
            "windSpeedMPH" => 8.5,
            "weather" => "Overcast Clouds",
            "icon" => "cloudy.png"
          }
        ],
        "profile" => %{"tz" => "America/Chicago"}
      }
    ]
  }

  # 12 hourly entries from now; hourly periods carry tempF (no maxTempF/minTempF).
  @hourly %{
    "success" => true,
    "error" => nil,
    "response" => [
      %{
        "periods" =>
          for i <- 0..11 do
            %{
              "timestamp" => @now + i * 3600,
              "tempF" => 70.0 + i,
              "feelslikeF" => 68.0 + i,
              "humidity" => 50 + i,
              "windSpeedMPH" => 5.0 + i,
              "pop" => i,
              "weather" => "Clear",
              "icon" => "clear.png"
            }
          end
      }
    ]
  }

  # 9 daily entries; daily periods carry maxTempF/minTempF + sunrise/sunsetISO,
  # alternating weather text so both normalize-to-token paths get exercised.
  # Icon tokens are classified from the "weather" text, not the "icon"
  # filename (see Xweather.icon/1) — the "icon" key here just mirrors what a
  # real response looks like and is otherwise unused by the adapter.
  @daily %{
    "success" => true,
    "error" => nil,
    "response" => [
      %{
        "periods" =>
          for i <- 0..8 do
            %{
              "timestamp" => @now + i * 86_400,
              "maxTempF" => 80.0 + i,
              "minTempF" => 60.0 + i,
              "pop" => i,
              "humidity" => 45 + i,
              "windSpeedMPH" => 6.0 + i,
              "weather" => if(rem(i, 2) == 0, do: "Partly Cloudy", else: "Rain Showers"),
              "icon" => if(rem(i, 2) == 0, do: "pcloudy.png", else: "shwrs.png"),
              "sunriseISO" => "2026-07-#{11 + i}T06:00:00-05:00",
              "sunsetISO" => "2026-07-#{11 + i}T20:00:00-05:00"
            }
          end
      }
    ]
  }

  defp stub_plug do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["filter"]} do
        {"/conditions/41.88,-87.63", _} -> Req.Test.json(conn, @current)
        {"/forecasts/41.88,-87.63", "1hr"} -> Req.Test.json(conn, @hourly)
        {"/forecasts/41.88,-87.63", "day"} -> Req.Test.json(conn, @daily)
      end
    end
  end

  describe "fetch_current_and_hourly/4" do
    test "returns current conditions" do
      assert {:ok, r} =
               Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: stub_plug())

      assert r.temp == 71.2
      assert r.feels_like == 69.8
      assert r.condition == "Overcast Clouds"
      # "Overcast Clouds" normalizes to the neutral "cloudy" token.
      assert r.icon == "cloudy"
      assert %DateTime{} = r.observed_at
      assert r.humidity == 55
      assert r.wind_speed == 8.5
      assert r.location_label == "Chicago, IL"
    end

    test "selects Celsius/kph fields for non-imperial units" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        body =
          put_in(@current, ["response", Access.at(0), "periods", Access.at(0)], %{
            "timestamp" => @now,
            "tempC" => 21.8,
            "feelslikeC" => 20.9,
            "humidity" => 55,
            "windSpeedKPH" => 13.7,
            "weather" => "Overcast Clouds",
            "icon" => "cloudy.png"
          })

        case {conn.request_path, conn.query_params["filter"]} do
          {"/conditions/41.88,-87.63", _} ->
            Req.Test.json(conn, body)

          {"/forecasts/41.88,-87.63", "1hr"} ->
            Req.Test.json(conn, %{"success" => true, "response" => []})
        end
      end

      assert {:ok, r} = Xweather.fetch_current_and_hourly(41.88, -87.63, "metric", plug: plug)
      assert r.temp == 21.8
      assert r.feels_like == 20.9
      assert r.wind_speed == 13.7
    end

    test "includes the next 8 forecast hours as structured attrs" do
      assert {:ok, r} =
               Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(r.hourly) == 8
      first = List.first(r.hourly)
      assert first.temp == 70.0
      assert first.icon == "clear"
      assert first.condition == "Clear"
      assert is_number(first.pop)
      assert is_number(first.humidity)
      assert is_number(first.wind_speed)
      assert %DateTime{} = first.forecast_time
    end

    test "converts pop from Xweather's 0-100 percentage to the shared 0.0-1.0 fraction" do
      # Regression: Xweather reports pop as a percentage (e.g. 79 for "79%"),
      # but the render layer multiplies by 100 assuming OWM's 0.0-1.0 fraction
      # convention — passed through unconverted, 79% rendered as "7900%".
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.request_path, conn.query_params["filter"]} do
          {"/conditions/41.88,-87.63", _} ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000}]}]
            })

          {"/forecasts/41.88,-87.63", "1hr"} ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "pop" => 79}]}]
            })
        end
      end

      assert {:ok, r} = Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)
      assert List.first(r.hourly).pop == 0.79
    end

    test "current conditions still return when the hourly call fails (best-effort)" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.request_path do
          "/conditions/41.88,-87.63" -> Req.Test.json(conn, @current)
          _ -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert {:ok, r} = Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)
      assert r.temp == 71.2
      assert r.hourly == []
    end

    test "returns an error when the current call is unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:http_status, 401}} =
               Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)
    end

    test "returns an error when the API reports success: false" do
      plug = fn conn ->
        Req.Test.json(conn, %{
          "success" => false,
          "error" => %{"code" => "invalid_client", "description" => "bad credentials"}
        })
      end

      assert {:error, {:api_error, %{"description" => "bad credentials"}}} =
               Xweather.fetch_current_and_hourly(41.88, -87.63, "imperial", plug: plug)
    end
  end

  describe "fetch_daily/4" do
    test "returns the next 7 days as structured attrs, all with real icons/conditions" do
      assert {:ok, days} = Xweather.fetch_daily(41.88, -87.63, "imperial", plug: stub_plug())

      assert length(days) == 7
      # Unlike OpenWeatherMap, every day gets a real icon/condition here.
      assert Enum.all?(days, &(&1.icon != nil))
      assert Enum.all?(days, &(&1.condition != nil))

      first = List.first(days)
      assert first.high == 80.0
      assert first.low == 60.0
      assert is_number(first.pop)
      assert first.icon == "partly_cloudy"
      assert first.condition == "Partly Cloudy"
      assert %DateTime{} = first.forecast_date
      assert %DateTime{} = first.sunrise
      assert %DateTime{} = first.sunset

      # "Rain Showers" normalizes to the neutral "showers" token.
      assert Enum.at(days, 1).icon == "showers"
      assert Enum.at(days, 1).condition == "Rain Showers"
    end

    test "returns {:error, :no_daily} when the endpoint returns no periods" do
      plug = fn conn ->
        Req.Test.json(conn, %{
          "success" => true,
          "error" => nil,
          "response" => [%{"periods" => []}]
        })
      end

      assert {:error, :no_daily} = Xweather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
    end

    test "returns {:error, :no_daily} on an HTTP failure" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, :no_daily} = Xweather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
    end
  end

  describe "condition classification (exhaustive over Xweather's documented weather-type codes)" do
    # One test per keyword in Xweather's documented, closed "weather type" code
    # table (A/BD/BN/BR/BS/BY/F/FC/FR/H/IC/IF/IP/K/L/R/RW/RS/SI/WM/S/SW/T/TO/UP/
    # VA/WP/ZF/ZL/ZR/ZY — https://www.xweather.com/docs/weather-api/reference/weather-codes),
    # not just the severe/exotic ones — the severe tokens (tornado/hurricane/
    # blizzard/ice_storm) are kept distinct from the everyday tokens
    # (thunderstorm/snow/fog) precisely so the wall display doesn't blend a
    # tornado or hurricane into "stormy" — see Provider's icon token docs.
    for {weather_text, expected_token} <- [
          {"Tornado", "tornado"},
          {"Funnel Cloud", "tornado"},
          {"Waterspout", "tornado"},
          {"Hurricane", "hurricane"},
          {"Tropical Storm", "hurricane"},
          {"Typhoon", "hurricane"},
          {"Blizzard", "blizzard"},
          # Contains the substring "storm" — must not fall through to the
          # generic thunderstorm branch.
          {"Winter Storm", "blizzard"},
          {"Freezing Rain", "ice_storm"},
          {"Freezing Drizzle", "ice_storm"},
          {"Freezing Spray", "ice_storm"},
          {"Ice Storm", "ice_storm"},
          # Contains the substring "storm" — must not fall through either.
          {"Tropical Storm Warning", "hurricane"},
          {"Thunderstorms", "thunderstorm"},
          {"Hail", "thunderstorm"},
          {"Snow", "snow"},
          {"Snow Showers", "snow"},
          {"Blowing Snow", "snow"},
          {"Sleet", "snow"},
          {"Ice Pellets", "snow"},
          {"Wintry Mix", "snow"},
          {"Rain Showers", "showers"},
          {"Rain", "rain"},
          {"Drizzle", "rain"},
          {"Fog", "fog"},
          {"Ice Fog", "fog"},
          {"Mist", "fog"},
          {"Smoke", "fog"},
          {"Haze", "fog"},
          {"Blowing Dust", "fog"},
          {"Blowing Sand", "fog"},
          {"Volcanic Ash", "fog"},
          {"Partly Cloudy", "partly_cloudy"},
          {"Mostly Cloudy", "cloudy"},
          {"Overcast", "cloudy"},
          {"Sunny", "clear"},
          {"Clear", "clear"},
          {"Fair", "clear"},
          {"Frost", "clear"},
          # "Unknown precipitation" — no keyword maps to it; must return nil
          # rather than guess (see Provider's icon token docs).
          {"Unknown Precipitation", nil}
        ] do
      test "classifies #{inspect(weather_text)} as #{inspect(expected_token)}" do
        plug = fn conn ->
          Req.Test.json(conn, %{
            "success" => true,
            "response" => [
              %{
                "periods" => [
                  %{
                    "timestamp" => 1_783_000_000,
                    "maxTempF" => 80.0,
                    "minTempF" => 60.0,
                    "weather" => unquote(weather_text)
                  }
                ]
              }
            ]
          })
        end

        assert {:ok, [day]} = Xweather.fetch_daily(41.88, -87.63, "imperial", plug: plug)
        assert day.icon == unquote(expected_token)
      end
    end
  end

  describe "fetch_alerts/4" do
    @alerts %{
      "success" => true,
      "error" => nil,
      "response" => [
        %{
          "id" => "abc123",
          "details" => %{
            "type" => "AW.TS.SV",
            "name" => "Severe Thunderstorm Warning",
            "emergency" => false,
            "priority" => 2,
            "color" => "FFA500",
            "cat" => "thunderstorm",
            "body" => "A severe thunderstorm warning has been issued.",
            "bodyFull" => "A severe thunderstorm warning has been issued for this area."
          },
          "timestamps" => %{
            "issued" => @now - 600,
            "begins" => @now,
            "expires" => @now + 3600
          }
        }
      ]
    }

    test "returns normalized alerts" do
      plug = fn conn ->
        case conn.request_path do
          "/alerts/41.88,-87.63" -> Req.Test.json(conn, @alerts)
        end
      end

      assert {:ok, [alert]} = Xweather.fetch_alerts(41.88, -87.63, "imperial", plug: plug)

      assert alert.alert_type == "AW.TS.SV"
      assert alert.severity == "severe"
      assert alert.priority == 2
      assert alert.category == "thunderstorm"
      assert alert.name == "Severe Thunderstorm Warning"
      assert alert.body == "A severe thunderstorm warning has been issued."
      assert alert.color == "FFA500"
      assert alert.emergency == false
      assert %DateTime{} = alert.begins_at
      assert %DateTime{} = alert.expires_at
      assert %DateTime{} = alert.issued_at
    end

    test "returns {:error, :no_alerts} when the response is empty" do
      plug = fn conn ->
        Req.Test.json(conn, %{"success" => true, "error" => nil, "response" => []})
      end

      assert {:error, :no_alerts} = Xweather.fetch_alerts(41.88, -87.63, "imperial", plug: plug)
    end

    test "returns {:error, :no_alerts} on an HTTP failure" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, :no_alerts} = Xweather.fetch_alerts(41.88, -87.63, "imperial", plug: plug)
    end
  end

  describe "alert severity normalization (exhaustive over Xweather's EX/SV/MD/MN suffix)" do
    for {type_code, expected_severity} <- [
          {"AW.TS.EX", "extreme"},
          {"AW.TS.SV", "severe"},
          {"AW.TS.MD", "moderate"},
          {"AW.TS.MN", "minor"},
          {"AW.TS.UNKNOWN", "minor"}
        ] do
      test "classifies #{inspect(type_code)} as #{inspect(expected_severity)}" do
        plug = fn conn ->
          Req.Test.json(conn, %{
            "success" => true,
            "response" => [
              %{
                "details" => %{"type" => unquote(type_code), "name" => "Test"},
                "timestamps" => %{}
              }
            ]
          })
        end

        assert {:ok, [alert]} = Xweather.fetch_alerts(41.88, -87.63, "imperial", plug: plug)
        assert alert.severity == unquote(expected_severity)
      end
    end
  end

  describe "credentials_configured?/0" do
    test "false when client id/secret are unset" do
      with_env(nil, nil, fn ->
        refute Xweather.credentials_configured?()
      end)
    end

    test "true when both client id and secret are set" do
      with_env("id", "secret", fn ->
        assert Xweather.credentials_configured?()
      end)
    end

    defp with_env(id, secret, fun) do
      original_id = Application.get_env(:family_dashboard, :xweather_client_id)
      original_secret = Application.get_env(:family_dashboard, :xweather_client_secret)
      Application.put_env(:family_dashboard, :xweather_client_id, id)
      Application.put_env(:family_dashboard, :xweather_client_secret, secret)

      try do
        fun.()
      after
        Application.put_env(:family_dashboard, :xweather_client_id, original_id)
        Application.put_env(:family_dashboard, :xweather_client_secret, original_secret)
      end
    end
  end
end
