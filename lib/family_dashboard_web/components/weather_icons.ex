defmodule FamilyDashboardWeb.WeatherIcons do
  @moduledoc """
  Renders the app's vendored weather condition icons inline as SVG.

  The dashboard used to render conditions as Unicode emoji, but the kiosk
  (Ubuntu Frame + WPE WebKit, no desktop session) has no color-emoji font
  installed, so every glyph rendered as a `[]` tofu box. These icons are
  self-hosted instead — see `assets/vendor/meteocons/README.md` for
  provenance and licensing (MIT, Meteocons by Bas Milius).

  Two variants are embedded per condition:

    * `:animated` — the icon's built-in SMIL animation, used for the single
      current-weather card so the wall display has one focal point of motion.
    * `:static` — the same artwork with the animation stripped, used for the
      8-hour and 7-day forecast rows so a dozen icons aren't all moving at
      once.

  Both are read from disk and embedded into the compiled module **at compile
  time** (`@external_resource` + `File.read!/1`), so rendering does zero
  runtime file I/O and Mix recompiles this module whenever a vendored SVG
  changes.

  Icons are rendered inline (`Phoenix.HTML.raw/1`) rather than via `<img
  src="...">`: SMIL animation only reliably plays when the SVG is part of the
  live DOM, and `<img>`-embedded SVGs render in a restricted mode that may not
  animate at all on WPE WebKit.
  """
  use Phoenix.Component

  # The vendored subset — keep in sync with assets/vendor/meteocons/{animated,static}/.
  @icon_files ~w(
    clear-day partly-cloudy-day cloudy rain drizzle thunderstorms snow mist
    tornado hurricane wind-snow sleet not-available thermometer
  )

  @vendor_dir Path.expand("../../../assets/vendor/meteocons", __DIR__)

  # Matches every vendored SVG's root tag regardless of its viewBox — some
  # icons crop tighter than the original "0 0 128 128" to make undersized
  # artwork (e.g. a single cloud shape) fill more of its icon slot, so this
  # can't be a fixed-string match. Since we inline the raw markup instead of
  # using <img>, the <svg> itself needs the sizing class, not just the
  # wrapping <span>.
  @svg_open_tag ~r/<svg viewBox="[^"]*" fill="none" xmlns="http:\/\/www\.w3\.org\/2000\/svg">/

  for variant <- [:animated, :static], name <- @icon_files do
    path = Path.join([@vendor_dir, Atom.to_string(variant), "#{name}.svg"])
    @external_resource path

    # A plain string, not yet Phoenix.HTML-safe: every rendered instance still
    # needs its internal ids namespaced by the caller's `id` attr (see
    # `weather_icon/1`) before it's safe to mark as trusted markup.
    svg =
      path
      |> File.read!()
      |> then(
        &Regex.replace(@svg_open_tag, &1, fn tag ->
          String.replace_trailing(tag, ">", " class=\"w-full h-full\">")
        end)
      )

    defp svg_content(unquote(variant), unquote(name)), do: unquote(svg)
  end

  # Maps the provider-neutral condition token (see
  # `FamilyDashboard.Weather.Provider`) to a vendored icon filename. Kept as
  # literal pattern matches (not built via interpolation) — this is the same
  # convention `alert_icon/1`/`alert_badge/1` use in DashboardLive, since a
  # dynamically-built lookup can fail silently with no compile or runtime error.
  defp icon_file(nil), do: "not-available"
  defp icon_file("clear"), do: "clear-day"
  defp icon_file("partly_cloudy"), do: "partly-cloudy-day"
  defp icon_file("cloudy"), do: "cloudy"
  defp icon_file("rain"), do: "rain"
  defp icon_file("showers"), do: "drizzle"
  defp icon_file("thunderstorm"), do: "thunderstorms"
  defp icon_file("snow"), do: "snow"
  defp icon_file("fog"), do: "mist"
  defp icon_file("tornado"), do: "tornado"
  defp icon_file("hurricane"), do: "hurricane"
  defp icon_file("blizzard"), do: "wind-snow"
  defp icon_file("ice_storm"), do: "sleet"
  defp icon_file(_unknown), do: "thermometer"

  @doc """
  Renders a weather condition icon.

  ## Examples

      <.weather_icon id="weather-current" variant={:animated} token={@weather.icon} class="w-20 h-20" />
      <.weather_icon id={"weather-hourly-\#{DateTime.to_unix(hour.forecast_time)}"} variant={:static} token={hour.icon} class="w-8 h-8 mx-auto" />
  """
  attr :variant, :atom, required: true, values: [:animated, :static]
  attr :token, :string, default: nil, doc: "a Provider condition token, or nil for 'no data'"
  attr :class, :string, default: nil

  attr :id, :string,
    required: true,
    doc: """
    A stable identifier unique to this icon's position on the page (e.g.
    "weather-hourly-\#{DateTime.to_unix(hour.forecast_time)}"), used to
    namespace this instance's internal SVG element ids. Every vendored icon
    reuses the same bare Figma ids for its gradients/clip-paths; the client's
    DOM patcher matches/moves elements by id across a live patch, so two icon
    instances sharing an id can have their rendered content swapped or
    silently dropped — this only shows up on an already-connected,
    long-running page (e.g. the kiosk's always-on tab), never on a fresh
    disconnected mount, which is why it's easy to miss in testing. Must never
    be derived from user input or third-party data — it's interpolated
    directly into the trusted SVG markup below.
    """

  def weather_icon(assigns) do
    file = icon_file(assigns.token)

    scoped_svg =
      assigns.variant
      |> svg_content(file)
      # [a-zA-Z0-9_-]: some icons' root <g> is id="<icon-slug>" (e.g.
      # id="clear-day", id="partly-cloudy-day") — the hyphen must be in the
      # character class or those ids silently fail to match and stay
      # duplicated across every instance of that icon on the page.
      |> then(&Regex.replace(~r/\bid="([a-zA-Z0-9_-]+)"/, &1, "id=\"#{assigns.id}-\\1\""))
      |> then(&Regex.replace(~r/url\(#([a-zA-Z0-9_-]+)\)/, &1, "url(##{assigns.id}-\\1)"))

    assigns =
      assigns
      |> assign(:file, file)
      |> assign(:svg, {:safe, scoped_svg})

    ~H"""
    <span data-weather-icon={@file} class={["inline-block", @class]}>{@svg}</span>
    """
  end
end
