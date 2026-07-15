# Weather Alerts Card + Hide News Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fetch, persist, and render Xweather weather alerts on the wall dashboard — with an operator-configurable severity+category filter, a whole-card "only show when active" gate, and severity-based coloring — and remove the placeholder News card.

**Architecture:** A new `WeatherAlert` Ash resource attaches to `WeatherReading` exactly like the existing `WeatherHourly`/`WeatherDaily` children. A 4th `Provider` behaviour callback (`fetch_alerts/4`) is implemented in the Xweather adapter (hitting its real, previously-unused `/alerts` endpoint) and stubbed in the OpenWeather adapter. `Sync.refresh_weather/1` fetches alerts best-effort in the same transaction that already creates the reading + hourly rows, on the same ~15-minute cadence — verified to carry no extra API cost. Unlike `daily`, alerts are **never** carried forward from the previous reading on a failed fetch. Three new scalar `Setting` attributes (min severity, hidden categories, show-body toggle) drive a render-time filter in `DashboardLive`, so operator edits and alert expiry both take effect on the existing 30-second clock tick without waiting for a refetch.

**Tech Stack:** Elixir ~1.17, Phoenix 1.8.9, Phoenix LiveView ~1.2.0, Ash 3.29.3, ash_sqlite, Oban 2.23.0 (SQLite engine), Req (HTTP), Tailwind v4 + daisyUI (static `@plugin` bundle, `themes: false`, two custom themes).

## Global Constraints

- `mix test` is aliased to `["ash.setup --quiet", "test"]` (`mix.exs`) — it auto-migrates and re-seeds the test DB. Never hand-run `mix ecto.migrate` for tests; just run `mix test`.
- After any Ash attribute/relationship change, run `mix ash.codegen <name>` (generates a migration + updates `priv/resource_snapshots/`) then `mix ash.migrate` before running tests that touch the changed resource.
- Ash resource files follow the spark formatter's section order: `actions`, `attributes`, `relationships`, `identities` last (see `lib/family_dashboard/weather_reading.ex`).
- Commit messages are plain imperative sentences, no prefix (e.g. "Add weather alert normalization to the Xweather adapter").
- The default weather provider is `FamilyDashboard.Weather.Xweather` (`config/test.exs:7`, `config/runtime.exs`), so every provider-facing test in this plan is written Xweather-shaped, matching the existing convention in `test/family_dashboard/sync_test.exs`.
- Xweather's `/alerts` endpoint costs exactly one API access, identical to `/conditions` or `/forecasts` — confirmed against Xweather's rate-limiting docs (https://www.aerisweather.com/support/docs/api/getting-started/rate-limiting/). This is why alerts ride the existing `refresh_weather` cadence rather than getting a separate interval/worker.
- Severity is always one of the 4 normalized tokens `"extreme" | "severe" | "moderate" | "minor"` — never a raw provider code — mirroring the existing icon-token pattern documented in `lib/family_dashboard/weather/provider.ex`.
- Never build a Tailwind/daisyUI class name via runtime string interpolation (e.g. `"alert-#{x}"`). Tailwind's content scanner (`assets/css/app.css`'s `@source` directives) only generates CSS for class-looking substrings that appear **literally** in a scanned file. This codebase already documents this constraint via `@color_shade_hex` in `dashboard_live.ex` (used for untrusted DB-driven colors). This plan's `severity_color/1` sidesteps it differently: it returns one of 4 **hardcoded literal string constants**, each of which appears verbatim in the source file, so the scanner finds them without needing an allowlist map.

## File Structure

- `lib/family_dashboard/weather_alert.ex` (new) — the `WeatherAlert` Ash resource, structurally identical to `weather_hourly.ex`/`weather_daily.ex`.
- `lib/family_dashboard/weather_reading.ex` (modify) — add the `has_many :alerts` relationship and load it in `:latest`.
- `lib/family_dashboard/weather_reaper.ex` (modify) — cascade-delete `WeatherAlert` rows alongside hourly/daily when a reading is reaped.
- `lib/family_dashboard/dashboard.ex` (modify) — register `WeatherAlert` in the domain.
- `lib/family_dashboard/weather/provider.ex` (modify) — add the `fetch_alerts/4` callback + moduledoc section.
- `lib/family_dashboard/weather.ex` (modify) — add the `fetch_alerts/4` dispatcher.
- `lib/family_dashboard/weather/xweather.ex` (modify) — implement `fetch_alerts/4` against the real `/alerts` endpoint.
- `lib/family_dashboard/weather/open_weather.ex` (modify) — stub `fetch_alerts/4`.
- `lib/family_dashboard/sync.ex` (modify) — fetch + persist alerts inside `refresh_weather`'s existing transaction; no carry-forward.
- `lib/family_dashboard/setting.ex` (modify) — add 3 alert-filter attributes to `@writable`.
- `lib/family_dashboard/validations/valid_severity.ex` (new) — validates `alerts_min_severity`, mirrors `valid_time_zone.ex`.
- `lib/family_dashboard_web/live/dashboard_live.ex` (modify) — remove the News card, replace the Weather Alerts placeholder with a real filtered/colored card.
- Test files: `test/family_dashboard/weather_alert_test.exs` (new), `test/family_dashboard/weather_reaper_test.exs` (modify), `test/family_dashboard/weather/xweather_test.exs` (modify), `test/family_dashboard/weather/open_weather_test.exs` (modify), `test/family_dashboard/sync_test.exs` (modify), `test/family_dashboard/setting_test.exs` (modify), `test/family_dashboard_web/live/dashboard_live_test.exs` (modify).

---

### Task 1: `WeatherAlert` resource, attached to `WeatherReading`

**Files:**
- Create: `lib/family_dashboard/weather_alert.ex`
- Modify: `lib/family_dashboard/weather_reading.ex`
- Modify: `lib/family_dashboard/weather_reaper.ex`
- Modify: `lib/family_dashboard/dashboard.ex`
- Test: `test/family_dashboard/weather_alert_test.exs` (new)
- Test: `test/family_dashboard/weather_reaper_test.exs` (modify)
- Generated: `priv/repo/migrations/<timestamp>_add_weather_alerts.exs`, `priv/resource_snapshots/repo/weather_alerts/*`, updated `priv/resource_snapshots/repo/weather_readings/*`

**Interfaces:**
- Produces: `FamilyDashboard.Dashboard.create_weather_alert/1,!/1`, `FamilyDashboard.Dashboard.list_weather_alerts/0,!/0`. `WeatherReading.latest_weather/0,!/0` now also loads `.alerts` (list, sorted `priority: :asc` — most significant first).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/weather_alert_test.exs`:

```elixir
defmodule FamilyDashboard.WeatherAlertTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates an alert row attached to a reading" do
    reading = create_reading()

    assert {:ok, alert} =
             Dashboard.create_weather_alert(%{
               weather_reading_id: reading.id,
               severity: "severe",
               alert_type: "AW.TS.SV",
               priority: 2,
               category: "thunderstorm",
               name: "Severe Thunderstorm Warning",
               body: "A severe thunderstorm warning has been issued.",
               color: "FFA500",
               emergency: false,
               begins_at: DateTime.utc_now() |> DateTime.truncate(:second),
               expires_at:
                 DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
               issued_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert alert.weather_reading_id == reading.id
    assert alert.severity == "severe"
    assert alert.name == "Severe Thunderstorm Warning"
  end

  test "requires severity" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_alert(%{weather_reading_id: reading.id, name: "Test"})
  end

  test "latest_weather loads alerts sorted by priority ascending" do
    reading = create_reading()

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "minor",
      priority: 4,
      name: "Minor advisory"
    })

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "extreme",
      priority: 1,
      name: "Extreme warning"
    })

    loaded = Dashboard.latest_weather!()
    assert Enum.map(loaded.alerts, & &1.name) == ["Extreme warning", "Minor advisory"]
  end
end
```

Replace the full contents of `test/family_dashboard/weather_reaper_test.exs`:

```elixir
defmodule FamilyDashboard.WeatherReaperTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, WeatherReaper}

  defp create_reading(observed_at) do
    Dashboard.record_weather!(%{observed_at: observed_at, temp: 70.0})
  end

  defp add_hourly(reading) do
    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: reading.observed_at,
      temp: 70.0
    })
  end

  defp add_daily(reading) do
    Dashboard.create_weather_daily!(%{
      weather_reading_id: reading.id,
      forecast_date: reading.observed_at,
      high: 80.0,
      low: 60.0
    })
  end

  defp add_alert(reading) do
    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "moderate",
      name: "Test alert"
    })
  end

  defp reading_ids do
    FamilyDashboard.WeatherReading |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes readings older than 48 hours, along with their hourly/daily/alert children" do
    old =
      create_reading(DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second))

    add_hourly(old)
    add_daily(old)
    add_alert(old)

    recent = create_reading(DateTime.utc_now() |> DateTime.truncate(:second))
    recent_hourly = add_hourly(recent)
    recent_daily = add_daily(recent)
    recent_alert = add_alert(recent)

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [recent.id]
    assert FamilyDashboard.WeatherHourly |> Ash.read!() |> Enum.map(& &1.id) == [recent_hourly.id]
    assert FamilyDashboard.WeatherDaily |> Ash.read!() |> Enum.map(& &1.id) == [recent_daily.id]
    assert FamilyDashboard.WeatherAlert |> Ash.read!() |> Enum.map(& &1.id) == [recent_alert.id]
  end

  test "keeps readings within the retention window" do
    within_window =
      create_reading(DateTime.utc_now() |> DateTime.add(-10, :hour) |> DateTime.truncate(:second))

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [within_window.id]
  end

  test "always protects the latest reading, even if it's older than the window" do
    only_reading =
      create_reading(DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second))

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [only_reading.id]
  end

  test "does nothing when there are no readings" do
    assert :ok = WeatherReaper.reap()
    assert reading_ids() == []
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/weather_alert_test.exs test/family_dashboard/weather_reaper_test.exs`
Expected: FAIL — `FamilyDashboard.WeatherAlert` doesn't exist and `Dashboard.create_weather_alert/1` is undefined.

- [ ] **Step 3: Create the `WeatherAlert` resource**

Create `lib/family_dashboard/weather_alert.ex`:

```elixir
defmodule FamilyDashboard.WeatherAlert do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_alerts"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :alert_type,
        :severity,
        :priority,
        :category,
        :name,
        :body,
        :color,
        :emergency,
        :begins_at,
        :expires_at,
        :issued_at,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    # The provider's raw alert code (e.g. Xweather's "AW.TS.MD"), kept for
    # debugging/display — never used for filtering, that's `severity`/`category`.
    attribute :alert_type, :string do
      public? true
    end

    # Normalized to "extreme" | "severe" | "moderate" | "minor" — see
    # FamilyDashboard.Weather.Provider. Never a raw provider value.
    attribute :severity, :string do
      allow_nil? false
      public? true
    end

    # Provider-specific numeric rank; lower is more significant.
    attribute :priority, :integer do
      public? true
    end

    attribute :category, :string do
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :body, :string do
      public? true
    end

    attribute :color, :string do
      public? true
    end

    attribute :emergency, :boolean do
      public? true
    end

    attribute :begins_at, :utc_datetime do
      public? true
    end

    attribute :expires_at, :utc_datetime do
      public? true
    end

    attribute :issued_at, :utc_datetime do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :weather_reading, FamilyDashboard.WeatherReading do
      allow_nil? false
      attribute_writable? true
    end
  end
end
```

- [ ] **Step 4: Add the `:alerts` relationship to `WeatherReading` and load it in `:latest`**

In `lib/family_dashboard/weather_reading.ex`, replace the `:latest` read action:

```elixir
    read :latest do
      get? true

      prepare build(
                sort: [observed_at: :desc, inserted_at: :desc],
                limit: 1,
                load: [:hourly, :daily, :alerts]
              )
    end
```

And in the same file, replace the `relationships do ... end` block:

```elixir
  relationships do
    has_many :hourly, FamilyDashboard.WeatherHourly do
      destination_attribute :weather_reading_id
      sort forecast_time: :asc
    end

    has_many :daily, FamilyDashboard.WeatherDaily do
      destination_attribute :weather_reading_id
      sort forecast_date: :asc
    end

    has_many :alerts, FamilyDashboard.WeatherAlert do
      destination_attribute :weather_reading_id
      sort priority: :asc
    end
  end
```

- [ ] **Step 5: Register `WeatherAlert` in the domain**

In `lib/family_dashboard/dashboard.ex`, add a new `resource` block inside `resources do ... end`, immediately after the `FamilyDashboard.WeatherDaily` block:

```elixir
    resource FamilyDashboard.WeatherAlert do
      define :create_weather_alert, action: :create
      define :list_weather_alerts, action: :read
    end
```

- [ ] **Step 6: Cascade-delete alerts in the reaper**

Replace the full contents of `lib/family_dashboard/weather_reaper.ex`:

```elixir
defmodule FamilyDashboard.WeatherReaper do
  @moduledoc """
  Deletes old `WeatherReading` rows (and their `WeatherHourly`/`WeatherDaily`/
  `WeatherAlert` children) on a daily cron schedule (see `config/config.exs`).
  Only the latest reading is ever read anywhere in the app — everything older
  is pure accumulated history with no read path.

  The current latest reading is always protected, even if it's older than the
  retention window: if refreshes break for an extended period, the dashboard
  should keep showing the last-known (stale) reading rather than reaping down
  to nothing.
  """

  require Ash.Query

  alias FamilyDashboard.{Dashboard, WeatherAlert, WeatherDaily, WeatherHourly, WeatherReading}

  @retention_hours 48

  @doc "Deletes readings older than the retention window, protecting the latest one."
  @spec reap() :: :ok
  def reap do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_hours, :hour)
    protected_id = latest_reading_id()

    reap_query =
      WeatherReading
      |> Ash.Query.filter(observed_at < ^cutoff)
      |> exclude_protected(protected_id)

    {:ok, _} =
      FamilyDashboard.Repo.transaction(fn ->
        ids = reap_query |> Ash.read!() |> Enum.map(& &1.id)

        unless ids == [] do
          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherHourly, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherDaily, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(
            Ash.Query.filter(WeatherAlert, weather_reading_id in ^ids),
            :destroy,
            %{},
            strategy: [:stream]
          )

          Ash.bulk_destroy!(reap_query, :destroy, %{}, strategy: [:stream])
        end
      end)

    :ok
  end

  defp latest_reading_id do
    case Dashboard.latest_weather() do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp exclude_protected(query, nil), do: query
  defp exclude_protected(query, id), do: Ash.Query.filter(query, id != ^id)
end
```

- [ ] **Step 7: Generate and run the migration**

Run: `mix ash.codegen add_weather_alerts`
Expected: a new file under `priv/repo/migrations/` that creates a `weather_alerts` table with a `weather_reading_id` foreign key to `weather_readings`. Read the generated migration before applying it — confirm it does exactly this and nothing else.

Run: `mix ash.migrate`
Expected: migration applies with no errors.

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/family_dashboard/weather_alert_test.exs test/family_dashboard/weather_reaper_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/family_dashboard/weather_alert.ex lib/family_dashboard/weather_reading.ex lib/family_dashboard/weather_reaper.ex lib/family_dashboard/dashboard.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/weather_alert_test.exs test/family_dashboard/weather_reaper_test.exs
git commit -m "Add a WeatherAlert resource attached to WeatherReading"
```

---

### Task 2: `fetch_alerts/4` provider callback (behaviour + both adapters + dispatcher)

**Files:**
- Modify: `lib/family_dashboard/weather/provider.ex`
- Modify: `lib/family_dashboard/weather.ex`
- Modify: `lib/family_dashboard/weather/xweather.ex`
- Modify: `lib/family_dashboard/weather/open_weather.ex`
- Test: `test/family_dashboard/weather/xweather_test.exs` (modify)
- Test: `test/family_dashboard/weather/open_weather_test.exs` (modify)

**Interfaces:**
- Consumes: nothing from Task 1 (this task has no Ash dependency — it only produces plain maps).
- Produces: `FamilyDashboard.Weather.fetch_alerts(lat, lon, units, opts \\ [])` returning `{:ok, [alert]} | {:error, :no_alerts}`, each `alert` shaped `%{alert_type:, severity:, priority:, category:, name:, body:, color:, emergency:, begins_at:, expires_at:, issued_at:}`. Task 3 (`Sync`) consumes this directly.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/weather/xweather_test.exs`, add these two `describe` blocks immediately before the final `end` of the module (after the existing `describe "credentials_configured?/0"` block):

```elixir
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
              %{"details" => %{"type" => unquote(type_code), "name" => "Test"}, "timestamps" => %{}}
            ]
          })
        end

        assert {:ok, [alert]} = Xweather.fetch_alerts(41.88, -87.63, "imperial", plug: plug)
        assert alert.severity == unquote(expected_severity)
      end
    end
  end
```

Replace the full contents of `test/family_dashboard/weather/open_weather_test.exs`'s final section — add this `describe` block immediately before the module's closing `end` (after whatever the last existing `describe` block is):

```elixir
  describe "fetch_alerts/4" do
    test "always returns {:error, :no_alerts} (not implemented for this provider)" do
      assert {:error, :no_alerts} = OpenWeather.fetch_alerts(41.88, -87.63, "imperial", [])
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/weather/xweather_test.exs test/family_dashboard/weather/open_weather_test.exs`
Expected: FAIL — `fetch_alerts/4` is undefined on both adapters.

- [ ] **Step 3: Add the callback to the `Provider` behaviour**

In `lib/family_dashboard/weather/provider.ex`, insert this new section into the moduledoc, immediately after the `## fetch_daily/4` section (before `## Icon tokens`):

```elixir
  ## `fetch_alerts/4`

  Returns `{:ok, alerts}` where `alerts` is a list of maps (one per currently
  active alert for this location), or `{:error, :no_alerts}` if the provider
  has none. Each alert map:

    * `:alert_type` — the provider's raw alert code, kept for debugging/display
      (e.g. Xweather's `"AW.TS.MD"`), or `nil`
    * `:severity` — normalized to one of `"extreme" | "severe" | "moderate" |
      "minor"` — never a raw provider severity value
    * `:priority` — a provider-specific numeric rank, lower is more
      significant, or `nil`
    * `:category` — a short category token (e.g. `"thunderstorm"`), or `nil`
    * `:name` — the alert's title (e.g. `"Severe Thunderstorm Warning"`)
    * `:body` — human-readable alert text, or `nil`
    * `:color` — the provider's official hex color for this alert, or `nil`
    * `:emergency` — boolean, or `nil`
    * `:begins_at`, `:expires_at`, `:issued_at` — `DateTime.t()` or `nil`

  Unlike `fetch_daily/4`'s carry-forward behavior in `Sync`, alert data is
  never carried forward from a previous refresh — a failed or empty
  `fetch_alerts/4` call must result in zero displayed alerts, since a stale
  severe-weather warning is far more harmful than a stale forecast.

```

Then replace the `@callback` lines at the bottom of the module:

```elixir
  @callback fetch_current_and_hourly(lat, lon, units, opts) :: {:ok, map()} | {:error, term()}
  @callback fetch_daily(lat, lon, units, opts) :: {:ok, [map()]} | {:error, :no_daily}
  @callback fetch_alerts(lat, lon, units, opts) :: {:ok, [map()]} | {:error, :no_alerts}
  @callback credentials_configured?() :: boolean()
```

- [ ] **Step 4: Add the dispatcher in `Weather`**

In `lib/family_dashboard/weather.ex`, add this function immediately after `fetch_daily/4` (before `credentials_configured?/0`):

```elixir
  @doc "Fetches active weather alerts. See `Provider.fetch_alerts/4`."
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(lat, lon, units, opts \\ []), do: provider().fetch_alerts(lat, lon, units, opts)
```

- [ ] **Step 5: Implement `fetch_alerts/4` in the Xweather adapter**

In `lib/family_dashboard/weather/xweather.ex`, add this function immediately after `fetch_daily/4` (before the private `place/2` function):

```elixir
  @doc """
  Fetches active weather alerts for `lat`/`lon`. Returns `{:ok, :no_alerts}`
  when the location has none.
  """
  @impl true
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(lat, lon, _units, opts \\ []) do
    case get("/alerts/#{place(lat, lon)}", [], opts) do
      {:ok, body} ->
        case body["response"] || [] do
          [] -> {:error, :no_alerts}
          alerts -> {:ok, Enum.map(alerts, &normalize_alert/1)}
        end

      {:error, _} ->
        {:error, :no_alerts}
    end
  end
```

Then add these private functions immediately after `daily_summary/2` (before `place_label/1`):

```elixir
  defp normalize_alert(alert) do
    details = alert["details"] || %{}
    timestamps = alert["timestamps"] || %{}

    %{
      alert_type: details["type"],
      severity: alert_severity(details["type"]),
      priority: details["priority"],
      category: details["cat"],
      name: details["name"],
      body: details["body"],
      color: details["color"],
      emergency: details["emergency"] || false,
      begins_at: parse_timestamp(timestamps["begins"]),
      expires_at: parse_timestamp(timestamps["expires"]),
      issued_at: parse_timestamp(timestamps["issued"])
    }
  end

  # Xweather's alert `type` code is a dot-separated string whose final segment
  # is a severity abbreviation (EX/SV/MD/MN) — see
  # https://www.xweather.com/docs/weather-api/endpoints/alerts. Normalized to
  # the closed set documented in FamilyDashboard.Weather.Provider so filter
  # config never depends on the raw provider code. Falls back to "minor"
  # (the least alarming tier) rather than crashing on an unrecognized code,
  # since `severity` is a required (`allow_nil? false`) attribute.
  defp alert_severity(nil), do: "minor"

  defp alert_severity(type) when is_binary(type) do
    case type |> String.split(".") |> List.last() do
      "EX" -> "extreme"
      "SV" -> "severe"
      "MD" -> "moderate"
      "MN" -> "minor"
      _ -> "minor"
    end
  end

  defp alert_severity(_), do: "minor"
```

- [ ] **Step 6: Stub `fetch_alerts/4` in the OpenWeather adapter**

In `lib/family_dashboard/weather/open_weather.ex`, add this function immediately after `fetch_daily/4` (before the private `best_effort_daily/3` function):

```elixir
  @doc """
  Not implemented — hurricane/tropical alert data lives in a separate feed
  this adapter doesn't fetch (see `icon/1` below). Always returns
  `{:error, :no_alerts}` so `Sync` treats this provider as having no alerts
  rather than raising `UndefinedFunctionError`.
  """
  @impl true
  @spec fetch_alerts(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_alerts}
  def fetch_alerts(_lat, _lon, _units, _opts \\ []), do: {:error, :no_alerts}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/family_dashboard/weather/xweather_test.exs test/family_dashboard/weather/open_weather_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/family_dashboard/weather/provider.ex lib/family_dashboard/weather.ex lib/family_dashboard/weather/xweather.ex lib/family_dashboard/weather/open_weather.ex test/family_dashboard/weather/xweather_test.exs test/family_dashboard/weather/open_weather_test.exs
git commit -m "Add a fetch_alerts/4 provider callback, implemented for Xweather"
```

---

### Task 3: Persist alerts in `Sync.refresh_weather` (best-effort, no carry-forward)

**Files:**
- Modify: `lib/family_dashboard/sync.ex`
- Test: `test/family_dashboard/sync_test.exs` (modify)

**Interfaces:**
- Consumes: `Weather.fetch_alerts/4` (Task 2), `Dashboard.create_weather_alert!/1` (Task 1).
- Produces: `Sync.refresh_weather/1` — same public signature/return values as before (`:ok | {:error, reason}`); the new reading it creates now also has 0+ `WeatherAlert` children, never carried forward from the previous reading.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/sync_test.exs`, replace the `defp weather_plug do ... end` helper inside `describe "refresh_weather/1"` (add an `/alerts/` branch so existing tests, which don't care about alerts, keep working instead of hitting an unmatched `cond`):

```elixir
    defp weather_plug do
      current = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "feelslikeF" => 68.0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      hourly = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "tempF" => 70.0,
                "pop" => 0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      daily = %{
        "success" => true,
        "response" => [
          %{
            "periods" => [
              %{
                "timestamp" => 1_783_000_000,
                "maxTempF" => 80.0,
                "minTempF" => 60.0,
                "weather" => "clear sky",
                "icon" => "clear.png"
              }
            ]
          }
        ]
      }

      alerts = %{"success" => true, "response" => []}

      fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, current)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, hourly)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "day" ->
            Req.Test.json(conn, daily)

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, alerts)
        end
      end
    end
```

In the same file, inside the `"borrows today's icon/condition from the hourly forecast when the daily endpoint's icon is missing"` test (in `describe "refresh_daily/1"`), replace its `plug = fn conn -> ... end` definition to add an `/alerts/` branch:

```elixir
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, current)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, hourly)

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "day" ->
            Req.Test.json(conn, daily_no_icon)

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{"success" => true, "response" => []})
        end
      end
```

Then, in `describe "refresh_weather/1"`, add these three tests immediately after the existing `"the current+hourly refresh does not fetch daily data"` test (before the `end` that closes the describe block):

```elixir
    test "persists and broadcasts alerts fetched alongside current+hourly" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [
                %{
                  "details" => %{
                    "type" => "AW.TS.SV",
                    "name" => "Severe Thunderstorm Warning",
                    "priority" => 2,
                    "cat" => "thunderstorm"
                  },
                  "timestamps" => %{"begins" => 1_783_000_000, "expires" => 1_783_003_600}
                }
              ]
            })
        end
      end

      assert :ok = Sync.refresh_weather(plug: plug)

      reading = Dashboard.latest_weather!()
      assert length(reading.alerts) == 1
      assert List.first(reading.alerts).name == "Severe Thunderstorm Warning"
      assert List.first(reading.alerts).severity == "severe"
    end

    test "a failing alerts fetch still yields a successful reading, with zero alerts" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert :ok = Sync.refresh_weather(plug: plug)

      reading = Dashboard.latest_weather!()
      assert reading.temp == 70.0
      assert reading.alerts == []
    end

    test "alerts are not carried forward when a later refresh's alert fetch fails" do
      populated_plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 70.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [
                %{
                  "details" => %{"type" => "AW.TS.SV", "name" => "Severe Thunderstorm Warning"},
                  "timestamps" => %{}
                }
              ]
            })
        end
      end

      failing_alerts_plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        cond do
          String.starts_with?(conn.request_path, "/conditions/") ->
            Req.Test.json(conn, %{
              "success" => true,
              "response" => [%{"periods" => [%{"timestamp" => 1_783_000_000, "tempF" => 71.0}]}]
            })

          String.starts_with?(conn.request_path, "/forecasts/") and
              conn.query_params["filter"] == "1hr" ->
            Req.Test.json(conn, %{"success" => true, "response" => [%{"periods" => []}]})

          String.starts_with?(conn.request_path, "/alerts/") ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end

      assert :ok = Sync.refresh_weather(plug: populated_plug)
      assert length(Dashboard.latest_weather!().alerts) == 1

      assert :ok = Sync.refresh_weather(plug: failing_alerts_plug)
      # Unlike `daily`, a failed alerts fetch on this NEW reading must not
      # inherit the previous reading's alerts — a stale severe-weather
      # warning is worse than a blank card.
      assert Dashboard.latest_weather!().alerts == []
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/sync_test.exs`
Expected: FAIL — the new tests fail (`reading.alerts` is always `[]` since nothing fetches/persists alerts yet), and depending on Elixir's `cond` behavior the pre-existing tests may also start erroring with a `CondClauseError` once the `/alerts/` requests start firing without a matching branch — this is expected until Step 3 lands.

- [ ] **Step 3: Fetch and persist alerts in `Sync`**

In `lib/family_dashboard/sync.ex`, replace the `true ->` branch inside `do_refresh_weather/2`:

```elixir
      true ->
        case Weather.fetch(setting.latitude, setting.longitude, setting.units || "metric", opts) do
          {:ok, attrs} ->
            attrs = Map.put(attrs, :alerts, best_effort_alerts(setting, opts))
            record_weather(attrs)
            record_weather_status(setting, nil)
            broadcast("weather", :weather_updated)
            :ok

          {:error, reason} ->
            record_weather_status(setting, humanize_weather_error(reason))
            {:error, reason}
        end
```

Then replace `record_weather/1` to also persist alerts, and add the new `best_effort_alerts/2` helper immediately after it:

```elixir
  # Creates the new reading + its hourly and alert rows, and copies the
  # previous reading's daily rows (+ high/low) forward so the 7-day widget
  # stays populated between the less-frequent daily job's runs. Alerts are
  # deliberately NOT copied forward — see best_effort_alerts/2.
  defp record_weather(attrs) do
    {hourly, attrs} = Map.pop(attrs, :hourly, [])
    {alerts, reading_attrs} = Map.pop(attrs, :alerts, [])
    prev = latest_reading()

    reading_attrs =
      reading_attrs
      |> Map.put(:high, prev && prev.high)
      |> Map.put(:low, prev && prev.low)

    {:ok, _} =
      FamilyDashboard.Repo.transaction(fn ->
        reading = Dashboard.record_weather!(reading_attrs)

        Enum.each(hourly, fn h ->
          Dashboard.create_weather_hourly!(Map.put(h, :weather_reading_id, reading.id))
        end)

        Enum.each(alerts, fn a ->
          Dashboard.create_weather_alert!(Map.put(a, :weather_reading_id, reading.id))
        end)

        if prev do
          Enum.each(prev.daily, fn d ->
            Dashboard.create_weather_daily!(%{
              weather_reading_id: reading.id,
              forecast_date: d.forecast_date,
              high: d.high,
              low: d.low,
              pop: d.pop,
              summary: d.summary,
              humidity: d.humidity,
              wind_speed: d.wind_speed,
              sunrise: d.sunrise,
              sunset: d.sunset,
              icon: d.icon,
              condition: d.condition
            })
          end)
        end

        reading
      end)

    :ok
  end

  # Best-effort: a failed or empty alerts fetch yields zero alerts on the new
  # reading rather than raising or blocking the current+hourly refresh — a
  # blank Weather Alerts card is far safer than either crashing the sync or
  # (as `daily` does) carrying a possibly-stale severe-weather warning
  # forward from the previous reading.
  defp best_effort_alerts(setting, opts) do
    case Weather.fetch_alerts(setting.latitude, setting.longitude, setting.units || "metric", opts) do
      {:ok, alerts} -> alerts
      {:error, _} -> []
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/sync_test.exs`
Expected: PASS (all describe blocks, including the untouched `sync_calendar/2` ones).

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/sync.ex test/family_dashboard/sync_test.exs
git commit -m "Persist weather alerts alongside current+hourly refreshes, without carry-forward"
```

---

### Task 4: Alert filter settings on the `Setting` resource

**Files:**
- Create: `lib/family_dashboard/validations/valid_severity.ex`
- Modify: `lib/family_dashboard/setting.ex`
- Test: `test/family_dashboard/setting_test.exs` (modify)

**Interfaces:**
- Produces: `Setting.alerts_min_severity` (string, default `"moderate"`), `Setting.alerts_hidden_categories` (string, default `""`, comma-delimited), `Setting.alerts_show_body` (boolean, default `false`) — all three writable via `Dashboard.update_setting/2` and auto-rendered as editable fields in `/admin` (ash_admin) since they're added to `@writable`. Task 5 (`DashboardLive`) reads these off `@setting`.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/setting_test.exs`, add these two `describe` blocks immediately after the existing `describe "time_zone validation"` block (before the module's closing `end`):

```elixir
  describe "alerts_min_severity validation" do
    test "rejects an invalid severity" do
      assert {:error, _} =
               Dashboard.update_setting(setting(), %{alerts_min_severity: "extreme-ish"})
    end

    test "accepts a valid severity" do
      assert {:ok, updated} = Dashboard.update_setting(setting(), %{alerts_min_severity: "severe"})
      assert updated.alerts_min_severity == "severe"
    end
  end

  describe "alert filter settings" do
    test "default to moderate severity, no hidden categories, and compact display" do
      assert setting().alerts_min_severity == "moderate"
      assert setting().alerts_hidden_categories == ""
      assert setting().alerts_show_body == false
    end

    test "hidden categories and show-body are writable" do
      assert {:ok, updated} =
               Dashboard.update_setting(setting(), %{
                 alerts_hidden_categories: "small craft advisory,air quality",
                 alerts_show_body: true
               })

      assert updated.alerts_hidden_categories == "small craft advisory,air quality"
      assert updated.alerts_show_body == true
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/setting_test.exs`
Expected: FAIL — `alerts_min_severity`/`alerts_hidden_categories`/`alerts_show_body` don't exist as attributes yet.

- [ ] **Step 3: Create the `ValidSeverity` validation**

Create `lib/family_dashboard/validations/valid_severity.ex`:

```elixir
defmodule FamilyDashboard.Validations.ValidSeverity do
  @moduledoc """
  Rejects an `alerts_min_severity` that isn't one of the four normalized
  severity tokens `FamilyDashboard.Weather.Provider.fetch_alerts/4` can
  produce (see its moduledoc). Without this, a typo written via `/admin`
  would make `DashboardLive`'s `severity_rank/1` comparison silently rank the
  threshold at 0 (matches nothing recognized) rather than raising — so the
  symptom would be "the alerts card never appears," discovered far from its
  cause. This validation catches the typo at write time instead.
  """
  use Ash.Resource.Validation

  @valid_severities ~w(extreme severe moderate minor)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :alerts_min_severity) do
      nil ->
        :ok

      severity when severity in @valid_severities ->
        :ok

      _ ->
        {:error,
         field: :alerts_min_severity,
         message: "must be one of: #{Enum.join(@valid_severities, ", ")}"}
    end
  end
end
```

- [ ] **Step 4: Add the three attributes to `Setting`**

Replace the full contents of `lib/family_dashboard/setting.ex`:

```elixir
defmodule FamilyDashboard.Setting do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  sqlite do
    table "settings"
    repo FamilyDashboard.Repo
  end

  # Fixed one-minute heartbeat. The `:tick` action reads this row live and
  # enqueues only the sync work that is currently due (see FamilyDashboard.Heartbeat).
  oban do
    scheduled_actions do
      schedule :heartbeat, "* * * * *" do
        action :tick
        queue :default
        worker_module_name FamilyDashboard.Workers.HeartbeatScheduler
      end
    end
  end

  actions do
    # Settings is a singleton; :current returns the single row (or nil if unseeded).
    read :current do
      get? true
      prepare build(sort: [inserted_at: :asc], limit: 1)
    end

    # Driven by the scheduled action above; enqueues due sync jobs.
    action :tick, :atom do
      run fn _input, _context ->
        FamilyDashboard.Heartbeat.run()
        {:ok, :ticked}
      end
    end

    @writable [
      :latitude,
      :longitude,
      :city_label,
      :units,
      :greeting,
      :time_zone,
      :calendar_sync_minutes,
      :weather_refresh_minutes,
      :daily_refresh_minutes,
      :sync_max_attempts,
      :alerts_min_severity,
      :alerts_hidden_categories,
      :alerts_show_body
    ]

    defaults [:read, create: @writable]

    # Non-atomic because the time_zone validation resolves the zone in Elixir
    # (can't be expressed as a DB expression). Fine for a rarely-edited singleton.
    update :update do
      primary? true
      require_atomic? false
      accept @writable
    end

    # System-set weather fetch status (not user-editable in the admin forms).
    update :record_weather_status do
      require_atomic? false
      accept [:weather_last_error, :weather_last_attempted_at, :daily_last_attempted_at]
    end
  end

  validations do
    validate {FamilyDashboard.Validations.ValidTimeZone, []}
    validate {FamilyDashboard.Validations.ValidSeverity, []}
  end

  attributes do
    uuid_primary_key :id

    attribute :latitude, :float do
      public? true
    end

    attribute :longitude, :float do
      public? true
    end

    attribute :city_label, :string do
      public? true
    end

    attribute :units, :string do
      public? true
    end

    # System-set status of the most recent weather refresh (surfaced on the
    # dashboard and in the admin so a blank weather panel is self-explanatory).
    attribute :weather_last_error, :string do
      public? true
    end

    attribute :weather_last_attempted_at, :utc_datetime do
      public? true
    end

    # IANA name (e.g. "America/Chicago"); the dashboard's "today" is computed here.
    attribute :time_zone, :string do
      public? true
      allow_nil? false
      default "America/Chicago"
    end

    # Scheduling knobs — edited in the settings panel, read live by the heartbeat.
    attribute :calendar_sync_minutes, :integer do
      public? true
      allow_nil? false
      default 15
      constraints min: 1
    end

    attribute :weather_refresh_minutes, :integer do
      public? true
      allow_nil? false
      default 15
      constraints min: 1
    end

    # The 7-day forecast changes slowly and its endpoint is flaky, so it refreshes
    # on its own, less-frequent schedule via a separate Oban job.
    attribute :daily_refresh_minutes, :integer do
      public? true
      allow_nil? false
      default 60
      constraints min: 1
    end

    attribute :daily_last_attempted_at, :utc_datetime do
      public? true
    end

    attribute :sync_max_attempts, :integer do
      public? true
      allow_nil? false
      default 3
      constraints min: 1
    end

    attribute :greeting, :string do
      public? true
    end

    # Minimum severity (of "extreme" | "severe" | "moderate" | "minor" — see
    # FamilyDashboard.Weather.Provider) an alert must meet to render on the
    # dashboard's Weather Alerts card. Validated by
    # FamilyDashboard.Validations.ValidSeverity.
    attribute :alerts_min_severity, :string do
      public? true
      allow_nil? false
      default "moderate"
    end

    # Comma-delimited alert `category` tokens (e.g. "small craft advisory,air
    # quality") to hide regardless of severity. Empty string means show every
    # category. A plain delimited string (not an Ash array type) so it stays
    # consistent with every other scalar setting on this resource and is
    # guaranteed-editable as a plain text field in ash_admin. Parsed in
    # DashboardLive.
    attribute :alerts_hidden_categories, :string do
      public? true
      allow_nil? false
      default ""
    end

    # Whether the Weather Alerts card shows each alert's body text beneath its
    # name, or just the compact name + active-until time.
    attribute :alerts_show_body, :boolean do
      public? true
      allow_nil? false
      default false
    end

    timestamps()
  end
end
```

- [ ] **Step 5: Generate and run the migration**

Run: `mix ash.codegen add_alert_settings`
Expected: a new file under `priv/repo/migrations/` adding `alerts_min_severity`, `alerts_hidden_categories`, `alerts_show_body` columns to `settings`. Read the generated migration before applying it.

Run: `mix ash.migrate`
Expected: migration applies with no errors.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/family_dashboard/setting_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/family_dashboard/validations/valid_severity.ex lib/family_dashboard/setting.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/setting_test.exs
git commit -m "Add operator-configurable alert severity/category filter settings"
```

---

### Task 5: Alerts card in the dashboard + remove the News card

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex`
- Test: `test/family_dashboard_web/live/dashboard_live_test.exs` (modify)

**Interfaces:**
- Consumes: `@weather.alerts` (Task 1/3), `@setting.alerts_min_severity`/`alerts_hidden_categories`/`alerts_show_body` (Task 4).
- Produces: a new `@active_alerts` assign (filtered, in-window alerts) and a rendered "Weather Alerts" card gated on it being non-empty. No News card in the rendered output.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard_web/live/dashboard_live_test.exs`, add these tests immediately after the existing `"surfaces the weather error when a fetch has failed and there's no reading"` test (before the `"shows all-day events..."` test):

```elixir
  test "does not render a News card", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "News"
  end

  test "shows the alerts card for an active alert that meets the default severity threshold", %{
    conn: conn
  } do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      name: "Severe Thunderstorm Warning",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ "Weather Alerts"
    assert html =~ "Severe Thunderstorm Warning"
  end

  test "hides the alerts card when the alert is below the configured severity threshold", %{
    conn: conn
  } do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{alerts_min_severity: "severe"})

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "moderate",
      name: "Frost Advisory",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Frost Advisory"
  end

  test "hides the alerts card once the alert has expired", %{conn: conn} do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      name: "Severe Thunderstorm Warning",
      begins_at: DateTime.add(now, -7200, :second),
      expires_at: DateTime.add(now, -3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Severe Thunderstorm Warning"
  end

  test "hides a hidden-category alert even when its severity meets the threshold", %{conn: conn} do
    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{alerts_hidden_categories: "small craft advisory"})

    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.create_weather_alert!(%{
      weather_reading_id: reading.id,
      severity: "severe",
      category: "small craft advisory",
      name: "Small Craft Advisory",
      begins_at: DateTime.add(now, -600, :second),
      expires_at: DateTime.add(now, 3600, :second)
    })

    {:ok, _live, html} = live(conn, ~p"/")

    refute html =~ "Small Craft Advisory"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: FAIL — the News card still renders, `@active_alerts` doesn't exist, and the alerts card is still the "Coming soon." placeholder.

- [ ] **Step 3: Extend `@default_setting` with the alert-filter defaults**

In `lib/family_dashboard_web/live/dashboard_live.ex`, replace the `@default_setting` module attribute:

```elixir
  @default_setting %{
    greeting: "Welcome home",
    city_label: nil,
    time_zone: "Etc/UTC",
    weather_last_error: nil,
    alerts_min_severity: "moderate",
    alerts_hidden_categories: "",
    alerts_show_body: false
  }
```

- [ ] **Step 4: Compute `@active_alerts` on mount, weather updates, and every clock tick**

Replace `mount/1`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
      Process.send_after(self(), :tick, @tick_ms)
    end

    socket = assign(socket, :agenda_days, @agenda_days)

    {:ok,
     socket
     |> assign_setting()
     |> assign_clock()
     |> load_weather()
     |> assign_active_alerts()
     |> load_events()}
  end
```

Replace `handle_info(:tick, socket)`:

```elixir
  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    prev_today = socket.assigns.today
    socket = socket |> assign_clock() |> assign_active_alerts()

    # Reload the agenda when the local day rolls over.
    socket = if socket.assigns.today != prev_today, do: load_events(socket), else: socket
    {:noreply, socket}
  end
```

Replace `handle_info(:weather_updated, socket)`:

```elixir
  def handle_info(:weather_updated, socket) do
    {:noreply, socket |> load_weather() |> assign_active_alerts()}
  end
```

Add `assign_active_alerts/1` and its private helpers immediately after `load_weather/1`:

```elixir
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
  defp hidden_categories(categories), do: String.split(categories, ",", trim: true)

  defp in_alert_window?(%{begins_at: begins_at, expires_at: expires_at}, now) do
    (is_nil(begins_at) or DateTime.compare(now, begins_at) != :lt) and
      (is_nil(expires_at) or DateTime.compare(now, expires_at) != :gt)
  end
```

- [ ] **Step 5: Remove the News card and render a real Weather Alerts card**

Replace the `<!-- News (placeholder, not yet wired to data) -->` and `<!-- Weather Alerts (placeholder, not yet wired to data) -->` sections (the two `<section>` blocks immediately before the left rail's closing `</div>`) with just:

```heex
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
```

- [ ] **Step 6: Add the severity/coloring/formatting render helpers**

Add these private functions immediately after `weather_emoji/1` (the last function in the module, right before the module's final `end`):

```elixir

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
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex test/family_dashboard_web/live/dashboard_live_test.exs
git commit -m "Render a filtered, severity-colored Weather Alerts card; remove the News placeholder"
```

---

## Final Verification

- [ ] Run the full suite: `mix test`. Expected: PASS (this re-runs `ash.setup --quiet` first, which re-migrates and re-seeds — no manual DB steps needed).
- [ ] Manual, with `XWEATHER_CLIENT_ID`/`XWEATHER_CLIENT_SECRET` set and a location configured in `/admin`: hit `/ops` → "Refresh weather now". Confirm on `/` that the Weather Alerts card appears only when an active, in-filter alert exists, colored per severity, and disappears when none do.
- [ ] Manual: in `/admin`, edit `alerts_min_severity`, `alerts_hidden_categories`, or `alerts_show_body`. Confirm the wall display reacts within ~30 seconds (no refetch needed) — this proves the filter is applied at render time via the clock tick, not just at fetch time.
- [ ] Manual: confirm the News card no longer appears anywhere in the left rail, and the rail's layout still fills the portrait viewport without a visible gap.
- [ ] Manual: force the daily reaper (`FamilyDashboard.WeatherReaper.reap/0` from an `iex -S mix` session, or wait for the 03:00 cron) against a reading older than 48h that has alert children, and confirm no orphaned `weather_alerts` rows remain (`FamilyDashboard.WeatherAlert |> Ash.read!()`).
