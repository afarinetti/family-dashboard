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

  # Resolved oklch() values for Tailwind's default color-shade palette (e.g. "orange-600"),
  # extracted from Tailwind's own build output. This app never writes literal
  # `border-<color>-<shade>` classes in source (they'd have to be dynamically built from
  # this DB-backed string), so Tailwind's scanner never generates the underlying
  # `--color-<shade>` theme variables in the compiled CSS — a `var(--color-orange-600)`
  # reference would silently resolve to nothing. Storing the resolved values here avoids
  # depending on theme variables the build never emits, and doubles as the allowlist: an
  # untrusted DB value can only ever produce one of these known colors, never arbitrary CSS.
  @color_shade_hex %{
    "amber-100" => "oklch(96.2% 0.059 95.617)",
    "amber-200" => "oklch(92.4% 0.12 95.746)",
    "amber-300" => "oklch(87.9% 0.169 91.605)",
    "amber-400" => "oklch(82.8% 0.189 84.429)",
    "amber-50" => "oklch(98.7% 0.022 95.277)",
    "amber-500" => "oklch(76.9% 0.188 70.08)",
    "amber-600" => "oklch(66.6% 0.179 58.318)",
    "amber-700" => "oklch(55.5% 0.163 48.998)",
    "amber-800" => "oklch(47.3% 0.137 46.201)",
    "amber-900" => "oklch(41.4% 0.112 45.904)",
    "amber-950" => "oklch(27.9% 0.077 45.635)",
    "blue-100" => "oklch(93.2% 0.032 255.585)",
    "blue-200" => "oklch(88.2% 0.059 254.128)",
    "blue-300" => "oklch(80.9% 0.105 251.813)",
    "blue-400" => "oklch(70.7% 0.165 254.624)",
    "blue-50" => "oklch(97% 0.014 254.604)",
    "blue-500" => "oklch(62.3% 0.214 259.815)",
    "blue-600" => "oklch(54.6% 0.245 262.881)",
    "blue-700" => "oklch(48.8% 0.243 264.376)",
    "blue-800" => "oklch(42.4% 0.199 265.638)",
    "blue-900" => "oklch(37.9% 0.146 265.522)",
    "blue-950" => "oklch(28.2% 0.091 267.935)",
    "cyan-100" => "oklch(95.6% 0.045 203.388)",
    "cyan-200" => "oklch(91.7% 0.08 205.041)",
    "cyan-300" => "oklch(86.5% 0.127 207.078)",
    "cyan-400" => "oklch(78.9% 0.154 211.53)",
    "cyan-50" => "oklch(98.4% 0.019 200.873)",
    "cyan-500" => "oklch(71.5% 0.143 215.221)",
    "cyan-600" => "oklch(60.9% 0.126 221.723)",
    "cyan-700" => "oklch(52% 0.105 223.128)",
    "cyan-800" => "oklch(45% 0.085 224.283)",
    "cyan-900" => "oklch(39.8% 0.07 227.392)",
    "cyan-950" => "oklch(30.2% 0.056 229.695)",
    "emerald-100" => "oklch(95% 0.052 163.051)",
    "emerald-200" => "oklch(90.5% 0.093 164.15)",
    "emerald-300" => "oklch(84.5% 0.143 164.978)",
    "emerald-400" => "oklch(76.5% 0.177 163.223)",
    "emerald-50" => "oklch(97.9% 0.021 166.113)",
    "emerald-500" => "oklch(69.6% 0.17 162.48)",
    "emerald-600" => "oklch(59.6% 0.145 163.225)",
    "emerald-700" => "oklch(50.8% 0.118 165.612)",
    "emerald-800" => "oklch(43.2% 0.095 166.913)",
    "emerald-900" => "oklch(37.8% 0.077 168.94)",
    "emerald-950" => "oklch(26.2% 0.051 172.552)",
    "fuchsia-100" => "oklch(95.2% 0.037 318.852)",
    "fuchsia-200" => "oklch(90.3% 0.076 319.62)",
    "fuchsia-300" => "oklch(83.3% 0.145 321.434)",
    "fuchsia-400" => "oklch(74% 0.238 322.16)",
    "fuchsia-50" => "oklch(97.7% 0.017 320.058)",
    "fuchsia-500" => "oklch(66.7% 0.295 322.15)",
    "fuchsia-600" => "oklch(59.1% 0.293 322.896)",
    "fuchsia-700" => "oklch(51.8% 0.253 323.949)",
    "fuchsia-800" => "oklch(45.2% 0.211 324.591)",
    "fuchsia-900" => "oklch(40.1% 0.17 325.612)",
    "fuchsia-950" => "oklch(29.3% 0.136 325.661)",
    "gray-100" => "oklch(96.7% 0.003 264.542)",
    "gray-200" => "oklch(92.8% 0.006 264.531)",
    "gray-300" => "oklch(87.2% 0.01 258.338)",
    "gray-400" => "oklch(70.7% 0.022 261.325)",
    "gray-50" => "oklch(98.5% 0.002 247.839)",
    "gray-500" => "oklch(55.1% 0.027 264.364)",
    "gray-600" => "oklch(44.6% 0.03 256.802)",
    "gray-700" => "oklch(37.3% 0.034 259.733)",
    "gray-800" => "oklch(27.8% 0.033 256.848)",
    "gray-900" => "oklch(21% 0.034 264.665)",
    "gray-950" => "oklch(13% 0.028 261.692)",
    "green-100" => "oklch(96.2% 0.044 156.743)",
    "green-200" => "oklch(92.5% 0.084 155.995)",
    "green-300" => "oklch(87.1% 0.15 154.449)",
    "green-400" => "oklch(79.2% 0.209 151.711)",
    "green-50" => "oklch(98.2% 0.018 155.826)",
    "green-500" => "oklch(72.3% 0.219 149.579)",
    "green-600" => "oklch(62.7% 0.194 149.214)",
    "green-700" => "oklch(52.7% 0.154 150.069)",
    "green-800" => "oklch(44.8% 0.119 151.328)",
    "green-900" => "oklch(39.3% 0.095 152.535)",
    "green-950" => "oklch(26.6% 0.065 152.934)",
    "indigo-100" => "oklch(93% 0.034 272.788)",
    "indigo-200" => "oklch(87% 0.065 274.039)",
    "indigo-300" => "oklch(78.5% 0.115 274.713)",
    "indigo-400" => "oklch(67.3% 0.182 276.935)",
    "indigo-50" => "oklch(96.2% 0.018 272.314)",
    "indigo-500" => "oklch(58.5% 0.233 277.117)",
    "indigo-600" => "oklch(51.1% 0.262 276.966)",
    "indigo-700" => "oklch(45.7% 0.24 277.023)",
    "indigo-800" => "oklch(39.8% 0.195 277.366)",
    "indigo-900" => "oklch(35.9% 0.144 278.697)",
    "indigo-950" => "oklch(25.7% 0.09 281.288)",
    "lime-100" => "oklch(96.7% 0.067 122.328)",
    "lime-200" => "oklch(93.8% 0.127 124.321)",
    "lime-300" => "oklch(89.7% 0.196 126.665)",
    "lime-400" => "oklch(84.1% 0.238 128.85)",
    "lime-50" => "oklch(98.6% 0.031 120.757)",
    "lime-500" => "oklch(76.8% 0.233 130.85)",
    "lime-600" => "oklch(64.8% 0.2 131.684)",
    "lime-700" => "oklch(53.2% 0.157 131.589)",
    "lime-800" => "oklch(45.3% 0.124 130.933)",
    "lime-900" => "oklch(40.5% 0.101 131.063)",
    "lime-950" => "oklch(27.4% 0.072 132.109)",
    "neutral-100" => "oklch(97% 0 0)",
    "neutral-200" => "oklch(92.2% 0 0)",
    "neutral-300" => "oklch(87% 0 0)",
    "neutral-400" => "oklch(70.8% 0 0)",
    "neutral-50" => "oklch(98.5% 0 0)",
    "neutral-500" => "oklch(55.6% 0 0)",
    "neutral-600" => "oklch(43.9% 0 0)",
    "neutral-700" => "oklch(37.1% 0 0)",
    "neutral-800" => "oklch(26.9% 0 0)",
    "neutral-900" => "oklch(20.5% 0 0)",
    "neutral-950" => "oklch(14.5% 0 0)",
    "orange-100" => "oklch(95.4% 0.038 75.164)",
    "orange-200" => "oklch(90.1% 0.076 70.697)",
    "orange-300" => "oklch(83.7% 0.128 66.29)",
    "orange-400" => "oklch(75% 0.183 55.934)",
    "orange-50" => "oklch(98% 0.016 73.684)",
    "orange-500" => "oklch(70.5% 0.213 47.604)",
    "orange-600" => "oklch(64.6% 0.222 41.116)",
    "orange-700" => "oklch(55.3% 0.195 38.402)",
    "orange-800" => "oklch(47% 0.157 37.304)",
    "orange-900" => "oklch(40.8% 0.123 38.172)",
    "orange-950" => "oklch(26.6% 0.079 36.259)",
    "pink-100" => "oklch(94.8% 0.028 342.258)",
    "pink-200" => "oklch(89.9% 0.061 343.231)",
    "pink-300" => "oklch(82.3% 0.12 346.018)",
    "pink-400" => "oklch(71.8% 0.202 349.761)",
    "pink-50" => "oklch(97.1% 0.014 343.198)",
    "pink-500" => "oklch(65.6% 0.241 354.308)",
    "pink-600" => "oklch(59.2% 0.249 0.584)",
    "pink-700" => "oklch(52.5% 0.223 3.958)",
    "pink-800" => "oklch(45.9% 0.187 3.815)",
    "pink-900" => "oklch(40.8% 0.153 2.432)",
    "pink-950" => "oklch(28.4% 0.109 3.907)",
    "purple-100" => "oklch(94.6% 0.033 307.174)",
    "purple-200" => "oklch(90.2% 0.063 306.703)",
    "purple-300" => "oklch(82.7% 0.119 306.383)",
    "purple-400" => "oklch(71.4% 0.203 305.504)",
    "purple-50" => "oklch(97.7% 0.014 308.299)",
    "purple-500" => "oklch(62.7% 0.265 303.9)",
    "purple-600" => "oklch(55.8% 0.288 302.321)",
    "purple-700" => "oklch(49.6% 0.265 301.924)",
    "purple-800" => "oklch(43.8% 0.218 303.724)",
    "purple-900" => "oklch(38.1% 0.176 304.987)",
    "purple-950" => "oklch(29.1% 0.149 302.717)",
    "red-100" => "oklch(93.6% 0.032 17.717)",
    "red-200" => "oklch(88.5% 0.062 18.334)",
    "red-300" => "oklch(80.8% 0.114 19.571)",
    "red-400" => "oklch(70.4% 0.191 22.216)",
    "red-50" => "oklch(97.1% 0.013 17.38)",
    "red-500" => "oklch(63.7% 0.237 25.331)",
    "red-600" => "oklch(57.7% 0.245 27.325)",
    "red-700" => "oklch(50.5% 0.213 27.518)",
    "red-800" => "oklch(44.4% 0.177 26.899)",
    "red-900" => "oklch(39.6% 0.141 25.723)",
    "red-950" => "oklch(25.8% 0.092 26.042)",
    "rose-100" => "oklch(94.1% 0.03 12.58)",
    "rose-200" => "oklch(89.2% 0.058 10.001)",
    "rose-300" => "oklch(81% 0.117 11.638)",
    "rose-400" => "oklch(71.2% 0.194 13.428)",
    "rose-50" => "oklch(96.9% 0.015 12.422)",
    "rose-500" => "oklch(64.5% 0.246 16.439)",
    "rose-600" => "oklch(58.6% 0.253 17.585)",
    "rose-700" => "oklch(51.4% 0.222 16.935)",
    "rose-800" => "oklch(45.5% 0.188 13.697)",
    "rose-900" => "oklch(41% 0.159 10.272)",
    "rose-950" => "oklch(27.1% 0.105 12.094)",
    "sky-100" => "oklch(95.1% 0.026 236.824)",
    "sky-200" => "oklch(90.1% 0.058 230.902)",
    "sky-300" => "oklch(82.8% 0.111 230.318)",
    "sky-400" => "oklch(74.6% 0.16 232.661)",
    "sky-50" => "oklch(97.7% 0.013 236.62)",
    "sky-500" => "oklch(68.5% 0.169 237.323)",
    "sky-600" => "oklch(58.8% 0.158 241.966)",
    "sky-700" => "oklch(50% 0.134 242.749)",
    "sky-800" => "oklch(44.3% 0.11 240.79)",
    "sky-900" => "oklch(39.1% 0.09 240.876)",
    "sky-950" => "oklch(29.3% 0.066 243.157)",
    "slate-100" => "oklch(96.8% 0.007 247.896)",
    "slate-200" => "oklch(92.9% 0.013 255.508)",
    "slate-300" => "oklch(86.9% 0.022 252.894)",
    "slate-400" => "oklch(70.4% 0.04 256.788)",
    "slate-50" => "oklch(98.4% 0.003 247.858)",
    "slate-500" => "oklch(55.4% 0.046 257.417)",
    "slate-600" => "oklch(44.6% 0.043 257.281)",
    "slate-700" => "oklch(37.2% 0.044 257.287)",
    "slate-800" => "oklch(27.9% 0.041 260.031)",
    "slate-900" => "oklch(20.8% 0.042 265.755)",
    "slate-950" => "oklch(12.9% 0.042 264.695)",
    "stone-100" => "oklch(97% 0.001 106.424)",
    "stone-200" => "oklch(92.3% 0.003 48.717)",
    "stone-300" => "oklch(86.9% 0.005 56.366)",
    "stone-400" => "oklch(70.9% 0.01 56.259)",
    "stone-50" => "oklch(98.5% 0.001 106.423)",
    "stone-500" => "oklch(55.3% 0.013 58.071)",
    "stone-600" => "oklch(44.4% 0.011 73.639)",
    "stone-700" => "oklch(37.4% 0.01 67.558)",
    "stone-800" => "oklch(26.8% 0.007 34.298)",
    "stone-900" => "oklch(21.6% 0.006 56.043)",
    "stone-950" => "oklch(14.7% 0.004 49.25)",
    "teal-100" => "oklch(95.3% 0.051 180.801)",
    "teal-200" => "oklch(91% 0.096 180.426)",
    "teal-300" => "oklch(85.5% 0.138 181.071)",
    "teal-400" => "oklch(77.7% 0.152 181.912)",
    "teal-50" => "oklch(98.4% 0.014 180.72)",
    "teal-500" => "oklch(70.4% 0.14 182.503)",
    "teal-600" => "oklch(60% 0.118 184.704)",
    "teal-700" => "oklch(51.1% 0.096 186.391)",
    "teal-800" => "oklch(43.7% 0.078 188.216)",
    "teal-900" => "oklch(38.6% 0.063 188.416)",
    "teal-950" => "oklch(27.7% 0.046 192.524)",
    "violet-100" => "oklch(94.3% 0.029 294.588)",
    "violet-200" => "oklch(89.4% 0.057 293.283)",
    "violet-300" => "oklch(81.1% 0.111 293.571)",
    "violet-400" => "oklch(70.2% 0.183 293.541)",
    "violet-50" => "oklch(96.9% 0.016 293.756)",
    "violet-500" => "oklch(60.6% 0.25 292.717)",
    "violet-600" => "oklch(54.1% 0.281 293.009)",
    "violet-700" => "oklch(49.1% 0.27 292.581)",
    "violet-800" => "oklch(43.2% 0.232 292.759)",
    "violet-900" => "oklch(38% 0.189 293.745)",
    "violet-950" => "oklch(28.3% 0.141 291.089)",
    "yellow-100" => "oklch(97.3% 0.071 103.193)",
    "yellow-200" => "oklch(94.5% 0.129 101.54)",
    "yellow-300" => "oklch(90.5% 0.182 98.111)",
    "yellow-400" => "oklch(85.2% 0.199 91.936)",
    "yellow-50" => "oklch(98.7% 0.026 102.212)",
    "yellow-500" => "oklch(79.5% 0.184 86.047)",
    "yellow-600" => "oklch(68.1% 0.162 75.834)",
    "yellow-700" => "oklch(55.4% 0.135 66.442)",
    "yellow-800" => "oklch(47.6% 0.114 61.907)",
    "yellow-900" => "oklch(42.1% 0.095 57.708)",
    "yellow-950" => "oklch(28.6% 0.066 53.813)",
    "zinc-100" => "oklch(96.7% 0.001 286.375)",
    "zinc-200" => "oklch(92% 0.004 286.32)",
    "zinc-300" => "oklch(87.1% 0.006 286.286)",
    "zinc-400" => "oklch(70.5% 0.015 286.067)",
    "zinc-50" => "oklch(98.5% 0 0)",
    "zinc-500" => "oklch(55.2% 0.016 285.938)",
    "zinc-600" => "oklch(44.2% 0.017 285.786)",
    "zinc-700" => "oklch(37% 0.013 285.805)",
    "zinc-800" => "oklch(27.4% 0.006 286.033)",
    "zinc-900" => "oklch(21% 0.006 285.885)",
    "zinc-950" => "oklch(14.1% 0.005 285.823)"
  }

  @default_setting %{
    greeting: "Welcome home",
    city_label: nil,
    time_zone: "Etc/UTC",
    weather_last_error: nil,
    alerts_min_severity: "moderate",
    alerts_hidden_categories: "",
    alerts_show_body: false,
    news_ticker_chars_per_second: 14
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "news")
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign_setting()
     |> assign_clock()
     |> load_weather()
     |> assign_active_alerts()
     |> load_events()
     |> load_news_items()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    prev_today = socket.assigns.today
    socket = socket |> assign_setting() |> assign_clock() |> assign_active_alerts()

    # Reload the agenda when the local day rolls over.
    socket = if socket.assigns.today != prev_today, do: load_events(socket), else: socket
    {:noreply, socket}
  end

  def handle_info(:events_updated, socket), do: {:noreply, load_events(socket)}

  def handle_info(:weather_updated, socket) do
    {:noreply, socket |> load_weather() |> assign_active_alerts()}
  end

  def handle_info(:news_updated, socket), do: {:noreply, load_news_items(socket)}

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

  # Recomputed on every weather update AND every 30s clock tick (not just on
  # fetch), so an operator's filter edit or an alert's natural expiry both
  # take effect within 30s instead of waiting for the next ~15-minute refresh.
  defp assign_active_alerts(socket) do
    %{weather: weather, setting: setting, now: now} = socket.assigns
    alerts = if weather, do: weather.alerts, else: []

    active =
      Enum.filter(alerts, fn alert ->
        severity_rank(alert.severity) >= severity_rank(setting.alerts_min_severity) and
          alert.category not in hidden_categories(setting.alerts_hidden_categories) and
          in_alert_window?(alert, now)
      end)

    assign(socket, :active_alerts, active)
  end

  defp hidden_categories(nil), do: []

  defp hidden_categories(categories) do
    categories
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp in_alert_window?(%{begins_at: begins_at, expires_at: expires_at}, now) do
    (is_nil(begins_at) or DateTime.compare(now, begins_at) != :lt) and
      (is_nil(expires_at) or DateTime.compare(now, expires_at) != :gt)
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

    events_by_date =
      from
      |> Dashboard.events_in_window!(to)
      |> Enum.group_by(&event_date(&1, tz))

    now = socket.assigns.now

    # Every day in [today, last] appears, even with zero events (the
    # template shows a "No events" placeholder) — previously only days with
    # at least one event were included.
    grouped =
      for date <- Date.range(today, last) do
        {date, events_by_date |> Map.get(date, []) |> reject_past(date, today, now)}
      end

    assign(socket, :events_by_day, grouped)
  end

  # Past events are hidden entirely rather than dimmed, but only on Today —
  # event_past?/2 restricted to today keeps the effect from bleeding into
  # future days (a future day's events are never "past").
  defp reject_past(events, date, today, now) when date == today,
    do: Enum.reject(events, &event_past?(&1, now))

  defp reject_past(events, _date, _today, _now), do: events

  defp load_news_items(socket) do
    items =
      Dashboard.list_news_items!()
      |> Enum.sort_by(&FamilyDashboard.NewsItem.effective_time/1, {:desc, DateTime})

    assign(socket, :news_items, items)
  end

  # A stable key derived from the current items' ids — used as (part of) the
  # ticker's DOM id. Unchanged across the 30s clock tick (same items, same
  # key, phx-update="ignore" leaves the node alone), but changes the moment
  # News.refresh_all/1 actually adds or removes an item, which remounts the
  # node and restarts the animation on genuinely new content.
  #
  # Sorted before hashing so the key depends only on the *set* of ids, not
  # their read order. Many items share an effective_time (no published_at,
  # so several land on the same inserted_at from one fetch batch), and
  # `load_news_items/1`'s sort_by is stable but SQLite gives no read-order
  # guarantee across ties — without sorting, the same item set could hash
  # differently between polls and spuriously remount the ticker mid-scroll.
  defp news_items_key(items), do: items |> Enum.map(& &1.id) |> Enum.sort() |> :erlang.phash2()

  # Scrolls at a roughly constant reading speed regardless of how many
  # headlines are queued, instead of a fixed-duration animation that would
  # crawl with few headlines and blur past with many. Clamped to a 10s floor
  # so one or two short headlines don't zip by. Pace is operator-configurable
  # via Setting.news_ticker_chars_per_second (edited in ash_admin).
  defp marquee_duration(items, chars_per_second) do
    total_chars =
      items
      |> Enum.map(&(String.length(&1.title) + String.length(&1.news_feed.label)))
      |> Enum.sum()

    max(round(total_chars / chars_per_second), 10)
  end

  # All-day events are date-only (stored at UTC midnight of their date) and must
  # not be timezone-shifted; timed events resolve to the local calendar day.
  defp event_date(%{all_day: true, starts_at: starts_at}, _tz), do: DateTime.to_date(starts_at)

  defp event_date(%{starts_at: starts_at}, tz) do
    starts_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  @impl true
  def render(assigns) do
    {hourly_min, hourly_max} = temp_bounds(hourly_temps(assigns.weather))
    {daily_min, daily_max} = daily_temp_bounds(daily_days(assigns.weather))

    assigns =
      assign(assigns,
        hourly_min: hourly_min,
        hourly_max: hourly_max,
        daily_min: daily_min,
        daily_max: daily_max,
        news_ticker_id: "news-ticker-#{news_items_key(assigns.news_items)}",
        marquee_duration:
          marquee_duration(assigns.news_items, assigns.setting.news_ticker_chars_per_second)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <!-- Portrait wall display (1080w x 1920h): 40% left rail, 60% right column,
           full-width news ticker pinned to the bottom. -->
      <div class="h-screen w-screen overflow-hidden bg-base-200 flex flex-col">
        <div class="flex-1 min-h-0 p-3 flex flex-row gap-2.5">
          <!-- Left rail (40%): clock/date, weather, weather alerts -->
          <div class="w-[40%] shrink-0 flex flex-col gap-3 overflow-hidden">
            <!-- Clock / greeting -->
            <section class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <p class="text-lg font-medium text-base-content/70">{@setting.greeting}</p>
                <p class="flex items-baseline gap-2.5 leading-none font-bold tabular-nums tracking-tight whitespace-nowrap">
                  <span class="text-[5.4rem] whitespace-nowrap">
                    <!-- Hour/colon/minute packed with no source whitespace between tags,
                         so HEEx doesn't insert a stray space between the digits. -->
                    <span class="inline-block min-w-[2ch] text-right">{Calendar.strftime(
                      @now,
                      "%-I"
                    )}</span><span class="inline-block -translate-y-[0.08em] animate-blink motion-reduce:animate-none">:</span><span class="inline-block">{Calendar.strftime(
                      @now,
                      "%M"
                    )}</span>
                  </span>
                  <span class="text-[1.7rem] font-semibold text-base-content/55">
                    {Calendar.strftime(@now, "%p")}
                  </span>
                </p>
                <p class="text-xl text-base-content/70 text-center">
                  {Calendar.strftime(@now, "%A, %B %-d")}
                </p>
              </div>
            </section>

            <!-- Current weather -->
            <section class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="Weather">
                  <:subtitle :if={@setting.city_label}>{@setting.city_label}</:subtitle>
                </.card_title>
                <div :if={@weather} class="flex flex-col gap-1">
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex items-center gap-3">
                      <span class="text-7xl">{weather_emoji(@weather.icon)}</span>
                      <p class="text-7xl font-bold tabular-nums">{round_temp(@weather.temp)}°</p>
                    </div>
                    <div class="text-right shrink-0">
                      <p :if={@weather.high && @weather.low} class="text-base text-base-content/60">
                        H {round_temp(@weather.high)}°
                      </p>
                      <p :if={@weather.high && @weather.low} class="text-base text-base-content/60">
                        L {round_temp(@weather.low)}°
                      </p>
                      <p class="text-base text-base-content/60">
                        feels {round_temp(@weather.feels_like)}°
                      </p>
                    </div>
                  </div>
                  <p class="text-base text-base-content/70 capitalize text-center">
                    {@weather.condition}
                  </p>
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

            <!-- 8-hour forecast -->
            <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="8 hour" />
                <p :if={@weather.hourly == []} class="text-xs text-base-content/40">
                  Hourly forecast unavailable.
                </p>
                <div class="flex flex-col gap-2.5">
                  <div
                    :for={hour <- @weather.hourly}
                    class="grid grid-cols-[3.75rem_2.125rem_2.75rem_1fr_2.625rem] items-center gap-2 min-h-[2rem]"
                  >
                    <span class="text-lg font-semibold tabular-nums whitespace-nowrap">
                      <span class="inline-block min-w-[2ch] text-right">{hour_number(
                        hour.forecast_time,
                        @tz
                      )}</span>
                      <span>{hour_meridiem(
                        hour.forecast_time,
                        @tz
                      )}</span>
                    </span>
                    <span class="text-2xl text-center">{weather_emoji(hour.icon)}</span>
                    <span class="text-lg font-bold text-right tabular-nums">{round_temp(hour.temp)}°</span>
                    <span class="relative h-[7px] rounded-full bg-base-300">
                      <span
                        class="absolute inset-y-0 left-0 rounded-full"
                        style={hourly_bar_style(hour, @hourly_min, @hourly_max)}
                      ></span>
                    </span>
                    <span :if={pop_pct(hour.pop)} class="text-base text-info text-right tabular-nums">
                      {pop_pct(hour.pop)}%
                    </span>
                    <span
                      :if={is_nil(pop_pct(hour.pop)) and is_number(hour.feels_like)}
                      class="text-base text-base-content/40 text-right tabular-nums"
                    >
                      ~{round_temp(hour.feels_like)}°
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <!-- 7-day forecast -->
            <section :if={@weather} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="7-day" />
                <p :if={@weather.daily == []} class="text-xs text-base-content/40">
                  Daily forecast unavailable right now.
                </p>
                <div class="flex flex-col gap-2.5">
                  <div
                    :for={day <- @weather.daily}
                    class="grid grid-cols-[3.5rem_2.125rem_2.375rem_1fr_2.375rem_2.625rem] items-center gap-2 min-h-[2rem]"
                  >
                    <span class="text-lg font-semibold">{day_short_label(day.forecast_date, @today)}</span>
                    <span class="text-2xl text-center">{weather_emoji(day.icon)}</span>
                    <span class="text-lg text-base-content/70 text-right tabular-nums">{round_temp(
                      day.low
                    )}°</span>
                    <span class="relative h-[7px] rounded-full bg-base-300">
                      <span
                        class="absolute inset-y-0 rounded-full"
                        style={daily_range_style(day, @daily_min, @daily_max)}
                      ></span>
                      <span
                        class="absolute top-1/2 h-[13px] w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-sm bg-base-100 shadow-[0_0_0_1.5px_oklch(0%_0_0_/_0.25)]"
                        style={daily_avg_marker_style(day, @daily_min, @daily_max)}
                      ></span>
                    </span>
                    <span class="text-lg font-bold text-right tabular-nums">{round_temp(day.high)}°</span>
                    <span :if={pop_pct(day.pop)} class="text-base text-info text-right tabular-nums">
                      {pop_pct(day.pop)}%
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <!-- Weather Alerts -->
            <section :if={@active_alerts != []} class="card card-sm bg-base-100 shadow-sm shrink-0">
              <div class="card-body">
                <.card_title label="Weather Alerts">
                  <:subtitle>{length(@active_alerts)}</:subtitle>
                </.card_title>
                <div class="flex flex-col gap-2">
                  <div
                    :for={alert <- @active_alerts}
                    class={"alert #{severity_color(alert.severity)} flex-col items-start gap-0.5 py-2"}
                  >
                    <div class="flex items-baseline justify-between gap-2 w-full">
                      <span class="font-semibold">{alert.name}</span>
                      <span class="text-sm opacity-80 shrink-0">{alert_until(alert.expires_at, @tz)}</span>
                    </div>
                    <p :if={@setting.alerts_show_body && alert.body} class="text-sm opacity-90">
                      {truncate_body(alert.body)}
                    </p>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <!-- Right column (60%): agenda -->
          <div class="flex-1 min-w-0 flex flex-col overflow-hidden">
            <!-- Agenda fills the remaining height; a single column clips at the bottom edge -->
            <section class="flex-1 min-h-0 card bg-base-100 shadow-sm">
              <div class="card-body min-h-0 overflow-hidden">
                <h2 class="text-2xl text-base-content/60 mb-2">Upcoming</h2>
                <div class="flex flex-col gap-y-4 overflow-hidden">
                  <div :for={{date, events} <- @events_by_day}>
                    <h3 class="text-2xl font-semibold text-base-content/80 border-b border-base-300 pb-1 mb-2">
                      {day_label(date, @today)}
                    </h3>
                    <p :if={events == []} class="text-xl text-base-content/50 py-1">
                      No events
                    </p>
                    <ul :if={events != []} class="space-y-2">
                      <%= for event <- events do %>
                        <% end_label = event_end_label(event, @tz) %>
                        <% color_hex = event_color_hex(event) %>
                        <% day_progress = event_day_progress(event, date, @tz) %>
                        <li class={[
                          "flex items-stretch text-xl rounded",
                          event_in_progress?(event, @now) && "bg-base-200/60"
                        ]}>
                          <div class="w-2 shrink-0 mr-2 flex flex-col items-center">
                            <%= if end_label do %>
                              <span
                                class={[
                                  "w-2 h-2 rounded-full shrink-0",
                                  is_nil(color_hex) && "bg-base-content/40"
                                ]}
                                style={color_hex && "background-color: #{color_hex}"}
                              ></span>
                              <span
                                class={[
                                  "w-1 flex-1 my-0.5 rounded-full",
                                  is_nil(color_hex) && "bg-base-300"
                                ]}
                                style={color_hex && "background-color: #{color_hex}"}
                              ></span>
                              <span
                                class={[
                                  "w-2 h-2 rounded-full border-2 shrink-0",
                                  is_nil(color_hex) && "border-base-content/40"
                                ]}
                                style={color_hex && "border-color: #{color_hex}"}
                              ></span>
                            <% else %>
                              <span
                                class={["w-1 flex-1 rounded-full", is_nil(color_hex) && "bg-base-300"]}
                                style={color_hex && "background-color: #{color_hex}"}
                              ></span>
                            <% end %>
                          </div>
                          <div class="flex-1 min-w-0 flex items-start gap-3">
                            <div class="w-28 shrink-0 tabular-nums leading-tight text-base-content/60">
                              <div>{event_start_label(event, @tz)}</div>
                              <div :if={end_label} class="text-lg text-base-content/30">
                                {end_label}
                              </div>
                            </div>
                            <div class="min-w-0 flex flex-col leading-tight">
                              <span class="font-medium">
                                {event.title}
                                <span
                                  :if={day_progress}
                                  class="text-lg font-normal text-base-content/30"
                                >
                                  {day_progress}
                                </span>
                              </span>
                              <span
                                :if={event.location}
                                class="text-lg text-base-content/50 truncate"
                              >
                                {event.location}
                              </span>
                            </div>
                          </div>
                        </li>
                      <% end %>
                    </ul>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </div>

        <!-- News ticker: content is server-driven (@news_items), motion is pure CSS.
             phx-update="ignore" + an items-derived id means a clock tick (unchanged
             items) never touches this node — the scroll keeps running uninterrupted;
             only a genuine news change (a different id) remounts it.

             The track div needs w-max: a block-level flex container's width
             defaults to filling its containing block (here, the 1080px-wide
             ticker bar), not its content — even though its shrink-0 children
             overflow that box and get clipped by the ancestor's
             overflow-hidden. Without w-max, translateX(-50%) moves by half
             of 1080px instead of half of the track's true (much larger)
             content width, so the animation crawls through only the first
             sliver of content instead of scrolling through all of it. -->
        <div
          :if={@news_items != []}
          id={@news_ticker_id}
          phx-update="ignore"
          class="shrink-0 w-full overflow-hidden bg-neutral text-neutral-content"
        >
          <div
            class="flex w-max whitespace-nowrap animate-marquee py-2"
            style={"animation-duration: #{@marquee_duration}s"}
          >
            <span :for={item <- @news_items} class="flex items-center gap-2 pr-10 shrink-0">
              <span class="badge badge-sm badge-outline">{item.news_feed.label}</span>
              <span class="text-lg">{item.title}</span>
            </span>
            <span
              :for={item <- @news_items}
              class="flex items-center gap-2 pr-10 shrink-0"
              aria-hidden="true"
            >
              <span class="badge badge-sm badge-outline">{item.news_feed.label}</span>
              <span class="text-lg">{item.title}</span>
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # A card title styled as an accent-colored eyebrow with a hairline rule beneath —
  # reuses the same border-base-300 treatment the agenda's day headers already have,
  # so the whole rail reads as one heading system instead of plain gray labels.
  attr :label, :string, required: true
  slot :subtitle

  defp card_title(assigns) do
    ~H"""
    <h2 class="flex items-baseline justify-between gap-2 mb-2.5 pb-[7px] border-b border-base-300">
      <span class="text-[0.7rem] font-bold uppercase tracking-wider text-primary">{@label}</span>
      <span :if={@subtitle != []} class="text-sm font-normal text-base-content/50">
        {render_slot(@subtitle)}
      </span>
    </h2>
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

  defp event_start_label(%{all_day: true}, _tz), do: "All day"

  defp event_start_label(%{starts_at: starts_at}, tz) do
    starts_at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I:%M %p")
  end

  # Line 2 of the time column, or nil to omit it entirely. All-day events
  # already say everything on line 1 ("All day"); events with no known end
  # can't say anything truthful about when they finish. A same-day timed
  # event gets its end time; an event that finishes on a later calendar day
  # gets the end day instead, since "which day" is the more useful fact at a
  # glance than "which minute".
  defp event_end_label(%{all_day: true}, _tz), do: nil
  defp event_end_label(%{ends_at: nil}, _tz), do: nil

  defp event_end_label(%{starts_at: starts_at, ends_at: ends_at}, tz) do
    start_date = starts_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    end_date = ends_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    if Date.compare(start_date, end_date) == :lt do
      "until " <> Calendar.strftime(end_date, "%a")
    else
      ends_at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I:%M %p")
    end
  end

  # The inclusive local start/end dates a genuinely multi-day event spans,
  # or nil for a single-day event or one with no known end (nothing to
  # measure a span against). All-day DTEND is exclusive per iCal, so the
  # stored `ends_at` date is one day past the real last day.
  defp event_inclusive_date_range(%{ends_at: nil}, _tz), do: nil

  defp event_inclusive_date_range(%{all_day: true, starts_at: starts_at, ends_at: ends_at}, _tz) do
    start_date = DateTime.to_date(starts_at)
    end_date = Date.add(DateTime.to_date(ends_at), -1)
    if Date.compare(start_date, end_date) == :lt, do: {start_date, end_date}
  end

  defp event_inclusive_date_range(%{starts_at: starts_at, ends_at: ends_at}, tz) do
    start_date = starts_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    end_date = ends_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    if Date.compare(start_date, end_date) == :lt, do: {start_date, end_date}
  end

  # "(Day X of Y)" suffix for a title, shown only on genuinely multi-day
  # events — `date` is the agenda day-group this row is rendered under.
  defp event_day_progress(event, date, tz) do
    case event_inclusive_date_range(event, tz) do
      nil ->
        nil

      {start_date, end_date} ->
        total = Date.diff(end_date, start_date) + 1
        current = Date.diff(date, start_date) + 1
        "(Day #{current} of #{total})"
    end
  end

  # "Happening right now" only makes sense for a timed event with a known
  # end — an all-day event isn't a moment, and an event with no ends_at
  # can't be bounded without guessing.
  defp event_in_progress?(%{all_day: true}, _now), do: false
  defp event_in_progress?(%{ends_at: nil}, _now), do: false

  defp event_in_progress?(%{starts_at: starts_at, ends_at: ends_at}, now) do
    DateTime.compare(starts_at, now) != :gt and DateTime.compare(now, ends_at) == :lt
  end

  # Dimmed only when we can say for certain the event is over — same
  # constraints as event_in_progress?/2 (timed, known end). The caller
  # additionally restricts this to the Today group so the effect never
  # bleeds into future days.
  defp event_past?(%{all_day: true}, _now), do: false
  defp event_past?(%{ends_at: nil}, _now), do: false
  defp event_past?(%{ends_at: ends_at}, now), do: DateTime.compare(ends_at, now) == :lt

  # A calendar's identity color must render as the same hue on every theme (see
  # the daisyUI color rules' theme-independence exception), so it's rendered as a
  # literal resolved color rather than a daisyUI semantic token. The stored value is
  # untrusted (nullable, unconstrained DB text) and must never crash this always-on
  # display, so only a value that's an exact key in @color_shade_hex is ever used —
  # that map doubles as the allowlist.
  defp event_color_hex(%{calendar: %{color: color}}) when is_binary(color) do
    Map.get(@color_shade_hex, color)
  end

  defp event_color_hex(_event), do: nil

  # --- 8-hour / 7-day bar helpers ---
  #
  # Both cards position each row's bar on one scale shared across all rows (rather
  # than normalizing each row independently), so the bars read as a real trend when
  # scanned top to bottom, not just decoration.

  defp hourly_temps(nil), do: []
  defp hourly_temps(weather), do: weather.hourly |> Enum.map(& &1.temp)

  defp daily_days(nil), do: []
  defp daily_days(weather), do: weather.daily

  defp temp_bounds(temps) do
    case Enum.reject(temps, &is_nil/1) do
      [] -> {0, 1}
      values -> {Enum.min(values), Enum.max(values)}
    end
  end

  # Padded a few degrees past the week's actual low/high so bars don't touch the
  # track edges.
  defp daily_temp_bounds(days) do
    lows = days |> Enum.map(& &1.low) |> Enum.reject(&is_nil/1)
    highs = days |> Enum.map(& &1.high) |> Enum.reject(&is_nil/1)

    case {lows, highs} do
      {[], _} -> {0, 1}
      {_, []} -> {0, 1}
      _ -> {Enum.min(lows) - 4, Enum.max(highs) + 4}
    end
  end

  # A value's position between min/max as a percent, clamped to [0, 100]. nil (a
  # missing temp) and a degenerate min == max range both fall back to a safe,
  # non-crashing default rather than propagating into a bad calculation.
  defp pct_between(nil, _min, _max), do: 0.0

  defp pct_between(value, min, max) when max > min do
    ((value - min) / (max - min)) |> max(0.0) |> min(1.0) |> Kernel.*(100) |> Float.round(2)
  end

  defp pct_between(_value, _min, _max), do: 50.0

  # A cool-to-warm hue ramp for a value's position in [min, max]. This is a pure
  # numeric mapping to a literal oklch() value, not a Tailwind class lookup, so
  # unlike @color_shade_hex there's no palette/allowlist concern here.
  defp temp_color(nil, _min, _max), do: "oklch(66% 0.16 122.5)"

  defp temp_color(temp, min, max) do
    hue = 245 - pct_between(temp, min, max) / 100 * 245
    "oklch(66% 0.16 #{Float.round(hue, 1)})"
  end

  defp hourly_bar_style(hour, min, max) do
    temp = hour.temp
    "width: #{pct_between(temp, min, max)}%; background: #{temp_color(temp, min, max)};"
  end

  defp daily_range_style(day, min, max) do
    left = pct_between(day.low, min, max)
    right = pct_between(day.high, min, max)
    low_color = temp_color(day.low, min, max)
    high_color = temp_color(day.high, min, max)

    "left: #{left}%; width: #{right - left}%; " <>
      "background: linear-gradient(to right, #{low_color}, #{high_color});"
  end

  defp daily_avg_marker_style(day, min, max) do
    "left: #{pct_between(day_average(day), min, max)}%;"
  end

  defp day_average(%{low: low, high: high}) when is_number(low) and is_number(high),
    do: (low + high) / 2

  defp day_average(_day), do: nil

  # Split so the template can reserve a fixed-width slot for the hour (mirrors the
  # clock's hour padding) — otherwise "11 PM"'s extra digit shifts its AM/PM out of
  # line with single-digit hours like "1 AM".
  defp hour_number(nil, _tz), do: ""

  defp hour_number(dt, tz) do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I")
  end

  defp hour_meridiem(nil, _tz), do: ""

  defp hour_meridiem(dt, tz) do
    dt |> DateTime.shift_zone!(tz) |> Calendar.strftime("%p")
  end

  defp day_short_label(nil, _today), do: ""

  # OWM's daily `dt` is always midnight UTC of the calendar day it forecasts (verified
  # against the live API across many locations/timezones) — a date, not a real instant.
  # Shifting it into the display timezone before reading its date would roll it back a
  # full day for any negative-UTC-offset zone, so it's read directly in UTC.
  defp day_short_label(dt, today) do
    date = DateTime.to_date(dt)
    if date == today, do: "Today", else: Calendar.strftime(date, "%a")
  end

  # Precipitation probability as a whole percent, or nil when zero/absent.
  defp pop_pct(pop) when is_number(pop) do
    pct = round(pop * 100)
    if pct > 0, do: pct, else: nil
  end

  defp pop_pct(_), do: nil

  # Map a provider-neutral icon token (see FamilyDashboard.Weather.Provider) to a
  # simple emoji (offline-friendly, no image fetch). A placeholder for a missing
  # icon (daily entries can omit it) — distinct from the unrecognized-token
  # fallback below, since "no data" and "data we don't know how to draw" are
  # different failure modes worth telling apart at a glance. Keying on tokens
  # rather than a provider's raw codes means this doesn't change when the
  # weather provider does (see `config :family_dashboard, :weather_provider`).
  defp weather_emoji(nil), do: "❓"

  defp weather_emoji(icon) do
    case icon do
      "clear" -> "☀️"
      "partly_cloudy" -> "🌤️"
      "cloudy" -> "☁️"
      "rain" -> "🌧️"
      "showers" -> "🌦️"
      "thunderstorm" -> "⛈️"
      "snow" -> "❄️"
      "fog" -> "🌫️"
      "tornado" -> "🌪️"
      "hurricane" -> "🌀"
      "blizzard" -> "🌨️"
      "ice_storm" -> "🧊"
      _ -> "🌡️"
    end
  end

  # --- weather alert helpers ---

  # Ranks the normalized severity tokens (see FamilyDashboard.Weather.Provider)
  # from least to most urgent, so the alerts_min_severity threshold can be
  # compared numerically. An unrecognized value ranks below "minor" (0) rather
  # than raising, so a value the UI doesn't understand yet is treated as
  # "always below threshold" instead of crashing the always-on display.
  defp severity_rank("minor"), do: 1
  defp severity_rank("moderate"), do: 2
  defp severity_rank("severe"), do: 3
  defp severity_rank("extreme"), do: 4
  defp severity_rank(_), do: 0

  # A full literal daisyUI semantic class per severity tier — never built via
  # string interpolation (e.g. "alert-#{token}"), since Tailwind's content
  # scan only sees classes that appear as literal strings in source (the same
  # constraint @color_shade_hex exists to work around for the agenda's
  # calendar colors, solved here by pattern-matching hardcoded literals
  # instead of an allowlist map, since daisyUI's semantic tokens are a small
  # fixed set).
  defp severity_color("extreme"), do: "alert-error"
  defp severity_color("severe"), do: "alert-warning"
  defp severity_color("moderate"), do: "alert-info"
  defp severity_color(_), do: "alert-neutral"

  defp alert_until(nil, _tz), do: nil

  defp alert_until(expires_at, tz) do
    "until " <> (expires_at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%-I:%M %p"))
  end

  @alert_body_limit 120

  defp truncate_body(nil), do: nil

  defp truncate_body(body) do
    if String.length(body) > @alert_body_limit do
      String.slice(body, 0, @alert_body_limit) <> "…"
    else
      body
    end
  end
end
