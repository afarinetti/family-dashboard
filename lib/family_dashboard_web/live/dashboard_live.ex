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
      <div class="h-screen w-screen overflow-hidden bg-base-200 p-8 flex flex-col gap-8">
        <!-- Top band: clock/greeting + weather, sized to ~40% of the screen -->
        <div class="flex gap-8 h-[38vh] shrink-0">
          <section class="basis-2/3 card bg-base-100 shadow-sm">
            <div class="card-body justify-center">
              <p class="text-4xl font-medium text-base-content/70">{@setting.greeting}</p>
              <p class="text-[10rem] leading-none font-bold tabular-nums tracking-tight">
                {Calendar.strftime(@now, "%-I:%M")}
                <span class="text-6xl font-semibold text-base-content/60">
                  {Calendar.strftime(@now, "%p")}
                </span>
              </p>
              <p class="text-3xl text-base-content/70">
                {Calendar.strftime(@now, "%A, %B %-d")}
              </p>
            </div>
          </section>

          <section class="basis-1/3 card bg-base-100 shadow-sm">
            <div class="card-body justify-center">
              <h2 class="text-2xl text-base-content/60">
                Weather<span :if={@setting.city_label} class="font-normal">· {@setting.city_label}</span>
              </h2>
              <div :if={@weather} class="flex items-center gap-6">
                <span class="text-8xl">{weather_emoji(@weather.icon)}</span>
                <div>
                  <p class="text-7xl font-bold tabular-nums">{round_temp(@weather.temp)}°</p>
                  <p class="text-2xl text-base-content/70 capitalize">{@weather.condition}</p>
                  <p :if={@weather.high && @weather.low} class="text-xl text-base-content/60">
                    H {round_temp(@weather.high)}° · L {round_temp(@weather.low)}°
                  </p>
                </div>
              </div>
              <div :if={is_nil(@weather)}>
                <p :if={@setting.weather_last_error} class="text-xl text-warning">
                  Weather unavailable — {@setting.weather_last_error}
                </p>
                <p :if={is_nil(@setting.weather_last_error)} class="text-xl text-base-content/50">
                  No weather data yet.
                </p>
              </div>
            </div>
          </section>
        </div>

        <!-- Agenda fills the rest; columns use the wide screen, scrolls only if overflowing -->
        <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
          <div class="card-body min-h-0">
            <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
            <p :if={@events_by_day == []} class="text-xl text-base-content/50 py-4">
              Nothing scheduled in the next {@agenda_days} days.
            </p>
            <div class="grid grid-cols-2 xl:grid-cols-3 gap-x-10 gap-y-4 overflow-y-auto content-start">
              <div :for={{date, events} <- @events_by_day} class="break-inside-avoid">
                <h3 class="text-xl font-semibold text-base-content/80 border-b border-base-300 pb-1 mb-2">
                  {day_label(date, @today)}
                </h3>
                <ul class="space-y-1.5">
                  <li :for={event <- events} class="flex items-baseline gap-3 text-lg">
                    <span class="w-28 shrink-0 text-base-content/60 tabular-nums">
                      {event_time(event, @tz)}
                    </span>
                    <span class="font-medium">{event.title}</span>
                    <span :if={event.location} class="text-base text-base-content/50 truncate">
                      · {event.location}
                    </span>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </section>
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

  # Map an OpenWeatherMap icon code to a simple emoji (offline-friendly, no image fetch).
  defp weather_emoji(nil), do: "❓"

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
