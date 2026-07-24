defmodule FamilyDashboardWeb.WeatherIconsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias FamilyDashboardWeb.WeatherIcons

  # Every token FamilyDashboard.Weather.Provider can produce, plus nil and an
  # unrecognized value — see WeatherIcons.icon_file/1. A token that maps to a
  # filename with no compiled svg_content/2 clause would raise
  # FunctionClauseError only at render time (the file-embedding `for` loop
  # only compiles the fixed @icon_files list), so this sweep is the only way
  # to catch that class of typo without rendering every icon manually.
  @known_tokens ~w(clear partly_cloudy cloudy rain showers thunderstorm snow fog
                   tornado hurricane blizzard ice_storm)

  describe "token -> icon mapping" do
    test "every known provider token renders without raising" do
      for token <- @known_tokens, variant <- [:animated, :static] do
        html =
          render_component(&WeatherIcons.weather_icon/1,
            id: "t-#{token}-#{variant}",
            variant: variant,
            token: token
          )

        assert html =~ "data-weather-icon="
      end
    end

    test "nil token falls back to the not-available icon" do
      html =
        render_component(&WeatherIcons.weather_icon/1, id: "t-nil", variant: :static, token: nil)

      assert html =~ ~s(data-weather-icon="not-available")
    end

    test "an unrecognized token falls back to the thermometer icon" do
      html =
        render_component(&WeatherIcons.weather_icon/1,
          id: "t-unknown",
          variant: :static,
          token: "some-new-provider-condition"
        )

      assert html =~ ~s(data-weather-icon="thermometer")
    end
  end

  describe "id namespacing (regression: duplicate SVG ids across instances)" do
    test "the vendored root id is scoped to the caller's id" do
      html =
        render_component(&WeatherIcons.weather_icon/1,
          id: "weather-current",
          variant: :animated,
          token: "clear"
        )

      assert html =~ ~s(id="weather-current-clear-day")
      refute html =~ ~s(id="clear-day")
    end

    test "two instances of the same icon on the same page share no element ids" do
      first =
        render_component(&WeatherIcons.weather_icon/1,
          id: "weather-hourly-1",
          variant: :static,
          token: "clear"
        )

      second =
        render_component(&WeatherIcons.weather_icon/1,
          id: "weather-hourly-2",
          variant: :static,
          token: "clear"
        )

      first_ids = Regex.scan(~r/\bid="([^"]+)"/, first, capture: :all_but_first) |> List.flatten()

      second_ids =
        Regex.scan(~r/\bid="([^"]+)"/, second, capture: :all_but_first) |> List.flatten()

      assert first_ids != []
      assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    end

    test "url(#...) references are rewritten to match their scoped id" do
      html =
        render_component(&WeatherIcons.weather_icon/1,
          id: "weather-current",
          variant: :animated,
          token: "clear"
        )

      referenced_ids =
        Regex.scan(~r/url\(#([a-zA-Z0-9_-]+)\)/, html, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      declared_ids =
        Regex.scan(~r/\bid="([^"]+)"/, html, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      assert MapSet.size(referenced_ids) > 0
      assert MapSet.subset?(referenced_ids, declared_ids)
    end
  end

  describe "variant selection" do
    test "the animated variant includes SMIL animation, the static variant doesn't" do
      animated =
        render_component(&WeatherIcons.weather_icon/1,
          id: "t-animated",
          variant: :animated,
          token: "clear"
        )

      static =
        render_component(&WeatherIcons.weather_icon/1,
          id: "t-static",
          variant: :static,
          token: "clear"
        )

      assert animated =~ "<animate"
      refute static =~ "<animate"
    end
  end

  describe "sizing" do
    test "the caller's class is applied to the wrapping span, and the svg always fills it" do
      html =
        render_component(&WeatherIcons.weather_icon/1,
          id: "t-sizing",
          variant: :static,
          token: "clear",
          class: "w-20 h-20"
        )

      assert html =~ ~s(class="inline-block w-20 h-20")
      assert html =~ ~s(class="w-full h-full")
    end
  end
end
