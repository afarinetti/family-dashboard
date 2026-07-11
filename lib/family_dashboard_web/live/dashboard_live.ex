defmodule FamilyDashboardWeb.DashboardLive do
  @moduledoc """
  The public wall-display dashboard: clock/greeting, weather, and agenda.

  It reads cheaply from the domain (Oban jobs do the slow fetching) and refreshes
  live via PubSub when calendar/weather data changes, plus a periodic clock tick.
  """
  use FamilyDashboardWeb, :live_view

  alias FamilyDashboard.Dashboard

  @tick_ms 30_000
  @agenda_days 7

  # Matches only real Tailwind CSS default palette color-shade pairs (e.g. "orange-600"),
  # so an untrusted DB value can never be interpolated into an arbitrary CSS var() name.
  @color_shade_regex ~r/^(slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-(50|100|200|300|400|500|600|700|800|900|950)\z/

  @default_setting %{
    greeting: "Welcome home",
    city_label: nil,
    time_zone: "Etc/UTC",
    weather_last_error: nil
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
      Process.send_after(self(), :tick, @tick_ms)
    end

    socket = assign(socket, :agenda_days, @agenda_days)
    {:ok, socket |> assign_setting() |> assign_clock() |> load_weather() |> load_events()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    prev_today = socket.assigns.today
    socket = assign_clock(socket)

    # Reload the agenda when the local day rolls over.
    socket = if socket.assigns.today != prev_today, do: load_events(socket), else: socket
    {:noreply, socket}
  end

  def handle_info(:events_updated, socket), do: {:noreply, load_events(socket)}
  def handle_info(:weather_updated, socket), do: {:noreply, load_weather(socket)}

  defp assign_setting(socket) do
    setting =
      case Dashboard.current_setting() do
        {:ok, %{} = setting} -> setting
        _ -> @default_setting
      end

    # Never trust the stored zone at render time — a bad value must not crash
    # the always-on display (validation also guards it at write time).
    assign(socket, setting: setting, tz: safe_zone(setting.time_zone))
  end

  defp assign_clock(socket) do
    now = DateTime.now!(socket.assigns.tz)
    assign(socket, now: now, today: DateTime.to_date(now))
  end

  defp safe_zone(time_zone) do
    case DateTime.now(time_zone) do
      {:ok, _} -> time_zone
      {:error, _} -> "Etc/UTC"
    end
  end

  defp load_weather(socket) do
    weather =
      case Dashboard.latest_weather() do
        {:ok, reading} -> reading
        _ -> nil
      end

    assign(socket, :weather, weather)
  end

  defp load_events(socket) do
    tz = socket.assigns.tz
    today = socket.assigns.today
    last = Date.add(today, @agenda_days)

    # Over-fetch a day on each side (timed events near midnight straddle UTC
    # dates); the correct per-event date is computed in event_date/2 and then
    # filtered to [today, last].
    from = DateTime.new!(Date.add(today, -1), ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(last, 1), ~T[23:59:59], "Etc/UTC")

    grouped =
      from
      |> Dashboard.events_in_window!(to)
      |> Enum.group_by(&event_date(&1, tz))
      |> Enum.filter(fn {date, _} ->
        Date.compare(date, today) != :lt and Date.compare(date, last) != :gt
      end)
      |> Enum.sort_by(fn {date, _} -> date end, Date)

    assign(socket, :events_by_day, grouped)
  end

  # All-day events are date-only (stored at UTC midnight of their date) and must
  # not be timezone-shifted; timed events resolve to the local calendar day.
  defp event_date(%{all_day: true, starts_at: starts_at}, _tz), do: DateTime.to_date(starts_at)

  defp event_date(%{starts_at: starts_at}, tz) do
    starts_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <!-- Portrait wall display (1080w x 1920h): 30% left rail, 70% right column. -->
      <div class="h-screen w-screen overflow-hidden bg-base-200 p-6 flex flex-row gap-5">
        <!-- Left rail (30%): clock/date, weather, news/alerts placeholders -->
        <div class="w-[30%] shrink-0 flex flex-col gap-3 overflow-hidden">
          <!-- Clock / greeting -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <p class="text-lg font-medium text-base-content/70">{@setting.greeting}</p>
              <p class="text-5xl leading-none font-bold tabular-nums tracking-tight">
                {Calendar.strftime(@now, "%-I:%M")}
                <span class="text-2xl font-semibold text-base-content/60">
                  {Calendar.strftime(@now, "%p")}
                </span>
              </p>
              <p class="text-xl text-base-content/70">{Calendar.strftime(@now, "%A, %B %-d")}</p>
            </div>
          </section>

          <!-- Current weather -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">
                Weather<span :if={@setting.city_label} class="font-normal">· {@setting.city_label}</span>
              </h2>
              <div :if={@weather} class="flex items-center gap-3">
                <span class="text-5xl">{weather_emoji(@weather.icon)}</span>
                <p class="text-4xl font-bold tabular-nums">{round_temp(@weather.temp)}°</p>
                <div>
                  <p class="text-base text-base-content/70 capitalize">{@weather.condition}</p>
                  <p :if={@weather.high && @weather.low} class="text-sm text-base-content/60">
                    H {round_temp(@weather.high)}° · L {round_temp(@weather.low)}°
                  </p>
                  <p class="text-sm text-base-content/60">feels {round_temp(@weather.feels_like)}°</p>
                </div>
              </div>
              <div :if={is_nil(@weather)}>
                <p :if={@setting.weather_last_error} class="text-base text-warning">
                  Weather unavailable — {@setting.weather_last_error}
                </p>
                <p :if={is_nil(@setting.weather_last_error)} class="text-base text-base-content/50">
                  No weather data yet.
                </p>
              </div>
            </div>
          </section>

          <!-- Hourly (next 8 hours) -->
          <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60 mb-1">Next hours</h2>
              <p :if={@weather.forecast["hourly"] in [nil, []]} class="text-xs text-base-content/40">
                Hourly forecast unavailable.
              </p>
              <div class="flex justify-between gap-0.5">
                <div
                  :for={hour <- @weather.forecast["hourly"] || []}
                  class="flex flex-col items-center gap-0.5 flex-1"
                >
                  <span class="text-[0.7rem] text-base-content/60">{hour_label(hour["dt"], @tz)}</span>
                  <span class="text-2xl">{weather_emoji(hour["icon"])}</span>
                  <span class="text-sm font-semibold tabular-nums">{round_temp(hour["temp"])}°</span>
                  <span :if={pop_pct(hour["pop"])} class="text-[0.7rem] text-info">{pop_pct(
                    hour["pop"]
                  )}%</span>
                </div>
              </div>
            </div>
          </section>

          <!-- 7-day -->
          <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60 mb-1">7-day</h2>
              <p :if={@weather.forecast["days"] in [nil, []]} class="text-xs text-base-content/40">
                Daily forecast unavailable right now.
              </p>
              <div class="flex justify-between gap-0.5">
                <div
                  :for={day <- @weather.forecast["days"] || []}
                  class="flex flex-col items-center gap-0.5 flex-1"
                >
                  <span class="text-[0.7rem] text-base-content/60">{day_short_label(
                    day["dt"],
                    @tz,
                    @today
                  )}</span>
                  <span class="text-2xl">{weather_emoji(day["icon"])}</span>
                  <span class="text-sm font-semibold tabular-nums">{round_temp(day["high"])}°</span>
                  <span class="text-[0.65rem] text-base-content/50 tabular-nums">{round_temp(
                    day["low"]
                  )}°</span>
                </div>
              </div>
            </div>
          </section>

          <!-- News (placeholder, not yet wired to data) -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">News</h2>
              <p class="text-xs text-base-content/40">Coming soon.</p>
            </div>
          </section>

          <!-- Weather Alerts (placeholder, not yet wired to data) -->
          <section class="card card-sm bg-base-100 shadow-sm shrink-0">
            <div class="card-body">
              <h2 class="text-sm text-base-content/60">Weather Alerts</h2>
              <p class="text-xs text-base-content/40">Coming soon.</p>
            </div>
          </section>
        </div>

        <!-- Right column (70%): agenda -->
        <div class="flex-1 min-w-0 flex flex-col overflow-hidden">
          <!-- Agenda fills the remaining height; a single column clips at the bottom edge -->
          <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
            <div class="card-body min-h-0 overflow-hidden">
              <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
              <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
                Nothing scheduled in the next {@agenda_days} days.
              </p>
              <div class="flex flex-col gap-y-4 overflow-hidden">
                <div :for={{date, events} <- @events_by_day}>
                  <h3 class="text-2xl font-semibold text-base-content/80 border-b border-base-300 pb-1 mb-2">
                    {day_label(date, @today)}
                  </h3>
                  <ul class="space-y-2">
                    <li
                      :for={event <- events}
                      class="flex items-baseline gap-3 text-xl border-l-2 border-base-300 pl-3"
                      style={event_border_style(event)}
                    >
                      <span class="w-28 shrink-0 text-base-content/60 tabular-nums">
                        {event_time(event, @tz)}
                      </span>
                      <span class="font-medium">{event.title}</span>
                      <span :if={event.location} class="text-lg text-base-content/50 truncate">
                        · {event.location}
                      </span>
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- presentation helpers ---

  defp round_temp(nil), do: "–"
  defp round_temp(temp), do: round(temp)

  defp day_label(date, today) do
    cond do
      date == today -> "Today"
      date == Date.add(today, 1) -> "Tomorrow"
      true -> Calendar.strftime(date, "%A, %b %-d")
    end
  end

  defp event_time(%{all_day: true}, _tz), do: "All day"

  defp event_time(%{starts_at: starts_at}, tz) do
    starts_at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I:%M %p")
  end

  # A calendar's identity color must render as the same hue on every theme (see
  # the daisyUI color rules' theme-independence exception), so it's rendered via the
  # raw Tailwind CSS variable rather than a daisyUI semantic token. The stored value
  # is untrusted (nullable, unconstrained DB text) and must never crash this always-on
  # display, so it's validated against a strict allowlist before being used at all.
  defp event_border_style(%{calendar: %{color: color}}) when is_binary(color) do
    if Regex.match?(@color_shade_regex, color) do
      "border-left-color: var(--color-#{color})"
    end
  end

  defp event_border_style(_event), do: nil

  defp hour_label(nil, _tz), do: ""

  defp hour_label(dt, tz) do
    dt |> DateTime.from_unix!() |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I %p")
  end

  defp day_short_label(nil, _tz, _today), do: ""

  defp day_short_label(dt, tz, today) do
    date = dt |> DateTime.from_unix!() |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    if date == today, do: "Today", else: Calendar.strftime(date, "%a")
  end

  # Precipitation probability as a whole percent, or nil when zero/absent.
  defp pop_pct(pop) when is_number(pop) do
    pct = round(pop * 100)
    if pct > 0, do: pct, else: nil
  end

  defp pop_pct(_), do: nil

  # Map an OpenWeatherMap icon code to a simple emoji (offline-friendly, no image
  # fetch). Blank for a missing icon (daily entries can omit it).
  defp weather_emoji(nil), do: ""

  defp weather_emoji(icon) do
    case String.slice(icon, 0, 2) do
      "01" -> "☀️"
      "02" -> "🌤️"
      "03" -> "☁️"
      "04" -> "☁️"
      "09" -> "🌧️"
      "10" -> "🌦️"
      "11" -> "⛈️"
      "13" -> "❄️"
      "50" -> "🌫️"
      _ -> "🌡️"
    end
  end
end
