# Admin / Ops Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the family dashboard's admin area manual sync triggers, a sync-status panel, calendars/settings backup+restore, and a normalized weather schema that captures every field OpenWeatherMap returns (currently most of it is discarded or hidden in an opaque JSON blob).

**Architecture:** A new password-gated `/ops` LiveView (`FamilyDashboardWeb.OpsLive`) becomes the ops hub — trigger buttons, a health panel, and backup/restore UI, all built on top of existing `FamilyDashboard.Dashboard` domain interfaces. Weather forecast data moves out of a `:map` blob into two new Ash resources (`WeatherHourly`, `WeatherDaily`) that belong to `WeatherReading`. A pure `FamilyDashboard.Backup` module handles JSON export/import for `calendars` + `settings` only. `ash_admin` at `/admin` is untouched and automatically picks up the new weather resources once they're registered in the domain.

**Tech Stack:** Elixir ~1.17, Phoenix 1.8.9, Phoenix LiveView ~1.2.0, Ash 3.29.3, ash_sqlite 0.2.17, ash_oban 0.8.10, Oban 2.23.0 (SQLite engine), Tailwind + daisyUI.

## Global Constraints

- Every new route (`/ops`, `/ops/backup.json`) lives inside the existing `scope "/" do pipe_through [:browser, :settings_area]` block in `lib/family_dashboard_web/router.ex` — the same shared-password gate as `/admin` and `/oban`. That scope has no `, FamilyDashboardWeb do` module alias, so route module references must be fully qualified (`FamilyDashboardWeb.OpsLive`, not `OpsLive`).
- `mix test` is aliased to `["ash.setup --quiet", "test"]` (see `mix.exs`) — every test run re-migrates and re-seeds the dev/test DB automatically. Do not hand-run `mix ecto.migrate` for tests; just run `mix test`.
- After any Ash resource attribute/relationship/identity change, run `mix ash.codegen <name>` (generates a migration + updates `priv/resource_snapshots/`) then `mix ash.migrate` before running tests that touch the changed resource.
- Commit messages in this repo are plain imperative sentences with no prefix (e.g. "Fix iCal RRULE UNTIL handling", not "feat: fix..."). Match that style.
- `/ops` is an operator page, not the wall display — normal interactive Tailwind/daisyUI sizing, not `DashboardLive`'s wall-scale type.
- Every Ash resource file in this codebase follows the spark formatter's section order: `actions`, `attributes`, `relationships`, then `identities` last (see `lib/family_dashboard/event.ex`). Follow it in every new/edited resource.
- The whole `/ops`, `/admin`, `/oban` area is gated by `FamilyDashboardWeb.Plugs.SettingsAuth` (shared password), not per-user policies — no additional authorization is needed inside `OpsLive` handlers.

---

### Task 1: Weather forecast schema — WeatherHourly, WeatherDaily, widened WeatherReading

This is one atomic task because `mix ash.codegen` generates one coherent migration from the *whole* resource graph — splitting resource creation from the migration would leave tests failing for the wrong reason (missing table, not missing logic).

**Files:**
- Create: `lib/family_dashboard/weather_hourly.ex`
- Create: `lib/family_dashboard/weather_daily.ex`
- Modify: `lib/family_dashboard/weather_reading.ex`
- Modify: `lib/family_dashboard/dashboard.ex`
- Test: `test/family_dashboard/weather_hourly_test.exs`
- Test: `test/family_dashboard/weather_daily_test.exs`
- Test: `test/family_dashboard/weather_reading_test.exs`
- Generated: `priv/repo/migrations/<timestamp>_normalize_weather.exs`, updated `priv/resource_snapshots/repo/weather_readings/*`, new `priv/resource_snapshots/repo/weather_hourly/*` and `.../weather_daily/*`

**Interfaces:**
- Produces: `FamilyDashboard.Dashboard.create_weather_hourly/1,!/1`, `FamilyDashboard.Dashboard.create_weather_daily/1,!/1`, `FamilyDashboard.Dashboard.list_weather_daily/0,!/0`. `WeatherReading.latest_weather/0,!/0` now returns a struct with loaded `.hourly` (list, sorted by `forecast_time` asc) and `.daily` (list, sorted by `forecast_date` asc) associations, and new scalar fields: `humidity, pressure, dew_point, uvi, clouds, visibility, wind_speed, wind_deg, wind_gust, sunrise, sunset`. The `forecast` map attribute no longer exists.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/weather_hourly_test.exs`:

```elixir
defmodule FamilyDashboard.WeatherHourlyTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates an hourly row attached to a reading" do
    reading = create_reading()

    assert {:ok, hourly} =
             Dashboard.create_weather_hourly(%{
               weather_reading_id: reading.id,
               forecast_time: DateTime.utc_now() |> DateTime.truncate(:second),
               temp: 71.0,
               icon: "01d"
             })

    assert hourly.weather_reading_id == reading.id
    assert hourly.temp == 71.0
  end

  test "requires forecast_time" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_hourly(%{weather_reading_id: reading.id, temp: 71.0})
  end
end
```

Create `test/family_dashboard/weather_daily_test.exs`:

```elixir
defmodule FamilyDashboard.WeatherDailyTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_reading do
    Dashboard.record_weather!(%{
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      temp: 70.0
    })
  end

  test "creates a daily row attached to a reading" do
    reading = create_reading()

    assert {:ok, daily} =
             Dashboard.create_weather_daily(%{
               weather_reading_id: reading.id,
               forecast_date: DateTime.utc_now() |> DateTime.truncate(:second),
               high: 80.0,
               low: 60.0
             })

    assert daily.weather_reading_id == reading.id
    assert daily.high == 80.0
  end

  test "requires forecast_date" do
    reading = create_reading()

    assert {:error, _} =
             Dashboard.create_weather_daily(%{weather_reading_id: reading.id, high: 80.0})
  end
end
```

Create `test/family_dashboard/weather_reading_test.exs`:

```elixir
defmodule FamilyDashboard.WeatherReadingTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  test "accepts the widened set of current-conditions fields" do
    assert {:ok, reading} =
             Dashboard.record_weather(%{
               observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
               temp: 70.0,
               feels_like: 68.0,
               condition: "clear sky",
               icon: "01d",
               humidity: 55,
               pressure: 1013,
               dew_point: 60.1,
               uvi: 3.2,
               clouds: 75,
               visibility: 10_000,
               wind_speed: 8.5,
               wind_deg: 210,
               wind_gust: 12.0,
               sunrise: DateTime.utc_now() |> DateTime.truncate(:second),
               sunset: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert reading.humidity == 55
    assert reading.wind_speed == 8.5
  end

  test "latest_weather loads hourly (asc) and daily (asc) associations" do
    reading =
      Dashboard.record_weather!(%{
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        temp: 70.0
      })

    later = DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.truncate(:second)
    sooner = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)

    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: later,
      temp: 72.0
    })

    Dashboard.create_weather_hourly!(%{
      weather_reading_id: reading.id,
      forecast_time: sooner,
      temp: 71.0
    })

    loaded = Dashboard.latest_weather!()
    assert Enum.map(loaded.hourly, & &1.forecast_time) == [sooner, later]
    assert loaded.daily == []
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/weather_hourly_test.exs test/family_dashboard/weather_daily_test.exs test/family_dashboard/weather_reading_test.exs`
Expected: FAIL — `FamilyDashboard.WeatherHourly`/`WeatherDaily` don't exist, and `Dashboard.record_weather/1` rejects the new fields (undefined attributes).

- [ ] **Step 3: Create the WeatherHourly resource**

Create `lib/family_dashboard/weather_hourly.ex`:

```elixir
defmodule FamilyDashboard.WeatherHourly do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_hourly"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :forecast_time,
        :temp,
        :feels_like,
        :pop,
        :humidity,
        :wind_speed,
        :icon,
        :condition,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    attribute :forecast_time, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :temp, :float do
      public? true
    end

    attribute :feels_like, :float do
      public? true
    end

    attribute :pop, :float do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :icon, :string do
      public? true
    end

    attribute :condition, :string do
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

- [ ] **Step 4: Create the WeatherDaily resource**

Create `lib/family_dashboard/weather_daily.ex`:

```elixir
defmodule FamilyDashboard.WeatherDaily do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_daily"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :forecast_date,
        :high,
        :low,
        :pop,
        :summary,
        :humidity,
        :wind_speed,
        :sunrise,
        :sunset,
        :icon,
        :condition,
        :weather_reading_id
      ]
    ]
  end

  attributes do
    uuid_primary_key :id

    attribute :forecast_date, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :high, :float do
      public? true
    end

    attribute :low, :float do
      public? true
    end

    attribute :pop, :float do
      public? true
    end

    attribute :summary, :string do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :sunrise, :utc_datetime do
      public? true
    end

    attribute :sunset, :utc_datetime do
      public? true
    end

    attribute :icon, :string do
      public? true
    end

    attribute :condition, :string do
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

- [ ] **Step 5: Widen WeatherReading and remove the forecast blob**

Replace the full contents of `lib/family_dashboard/weather_reading.ex`:

```elixir
defmodule FamilyDashboard.WeatherReading do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "weather_readings"
    repo FamilyDashboard.Repo
  end

  actions do
    # The most recent reading; the dashboard renders this one. Loads its
    # forecast children so callers never need a second query for the
    # 8-hour/7-day widgets.
    read :latest do
      get? true
      prepare build(sort: [observed_at: :desc], limit: 1, load: [:hourly, :daily])
    end

    @fields [
      :observed_at,
      :temp,
      :feels_like,
      :condition,
      :icon,
      :high,
      :low,
      :humidity,
      :pressure,
      :dew_point,
      :uvi,
      :clouds,
      :visibility,
      :wind_speed,
      :wind_deg,
      :wind_gust,
      :sunrise,
      :sunset,
      :location_label
    ]

    defaults [:read, :destroy, create: @fields]

    # Non-atomic: kept from the original resource since callers pass a full
    # attrs map, not an atomic-safe expression update.
    update :update do
      primary? true
      require_atomic? false
      accept @fields
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :observed_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :temp, :float do
      public? true
    end

    attribute :feels_like, :float do
      public? true
    end

    attribute :condition, :string do
      public? true
    end

    attribute :icon, :string do
      public? true
    end

    attribute :high, :float do
      public? true
    end

    attribute :low, :float do
      public? true
    end

    attribute :humidity, :integer do
      public? true
    end

    attribute :pressure, :integer do
      public? true
    end

    attribute :dew_point, :float do
      public? true
    end

    attribute :uvi, :float do
      public? true
    end

    attribute :clouds, :integer do
      public? true
    end

    attribute :visibility, :integer do
      public? true
    end

    attribute :wind_speed, :float do
      public? true
    end

    attribute :wind_deg, :integer do
      public? true
    end

    attribute :wind_gust, :float do
      public? true
    end

    attribute :sunrise, :utc_datetime do
      public? true
    end

    attribute :sunset, :utc_datetime do
      public? true
    end

    attribute :location_label, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :hourly, FamilyDashboard.WeatherHourly do
      destination_attribute :weather_reading_id
      sort forecast_time: :asc
    end

    has_many :daily, FamilyDashboard.WeatherDaily do
      destination_attribute :weather_reading_id
      sort forecast_date: :asc
    end
  end
end
```

- [ ] **Step 6: Register the new resources in the domain**

In `lib/family_dashboard/dashboard.ex`, add two new `resource` blocks inside `resources do ... end`, after the existing `FamilyDashboard.WeatherReading` block:

```elixir
    resource FamilyDashboard.WeatherHourly do
      define :create_weather_hourly, action: :create
    end

    resource FamilyDashboard.WeatherDaily do
      define :create_weather_daily, action: :create
      define :list_weather_daily, action: :read
    end
```

The full `resources do ... end` block should now read:

```elixir
  resources do
    resource FamilyDashboard.Calendar do
      define :list_calendars, action: :read
      define :get_calendar, action: :read, get_by: [:id]
      define :create_calendar, action: :create
      define :update_calendar, action: :update
      define :destroy_calendar, action: :destroy
    end

    resource FamilyDashboard.Event do
      define :events_in_window, action: :in_window, args: [:from, :to]
      define :create_event, action: :create
    end

    resource FamilyDashboard.WeatherReading do
      define :latest_weather, action: :latest, not_found_error?: false
      define :record_weather, action: :create
      define :update_weather_reading, action: :update
    end

    resource FamilyDashboard.WeatherHourly do
      define :create_weather_hourly, action: :create
    end

    resource FamilyDashboard.WeatherDaily do
      define :create_weather_daily, action: :create
      define :list_weather_daily, action: :read
    end

    resource FamilyDashboard.Setting do
      define :current_setting, action: :current, not_found_error?: false
      define :create_setting, action: :create
      define :update_setting, action: :update
      define :record_weather_status, action: :record_weather_status
    end
  end
```

- [ ] **Step 7: Generate and run the migration**

Run: `mix ash.codegen normalize_weather`
Expected: a new file under `priv/repo/migrations/` that creates `weather_hourly` and `weather_daily` tables (each with a `weather_reading_id` foreign key to `weather_readings`), adds the new scalar columns to `weather_readings`, and drops its `forecast` column. Read the generated migration before applying it — confirm it does exactly this and nothing else.

Run: `mix ash.migrate`
Expected: migration applies with no errors.

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/family_dashboard/weather_hourly_test.exs test/family_dashboard/weather_daily_test.exs test/family_dashboard/weather_reading_test.exs`
Expected: PASS. (`mix test`'s `ash.setup --quiet` alias step re-migrates the test DB automatically first.)

- [ ] **Step 9: Commit**

```bash
git add lib/family_dashboard/weather_hourly.ex lib/family_dashboard/weather_daily.ex lib/family_dashboard/weather_reading.ex lib/family_dashboard/dashboard.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/weather_hourly_test.exs test/family_dashboard/weather_daily_test.exs test/family_dashboard/weather_reading_test.exs
git commit -m "Normalize weather forecast data into WeatherHourly and WeatherDaily resources"
```

---

### Task 2: Rewrite the Weather fetch facade for the normalized schema

**Files:**
- Modify: `lib/family_dashboard/weather.ex`
- Test: `test/family_dashboard/weather_test.exs` (full rewrite)

**Interfaces:**
- Consumes: nothing from Task 1 directly (this module has no Ash dependency), but its output shape must match what Task 3's `Sync` rewrite expects.
- Produces: `Weather.fetch/4` returns `{:ok, %{observed_at:, temp:, feels_like:, condition:, icon:, humidity:, pressure:, dew_point:, uvi:, clouds:, visibility:, wind_speed:, wind_deg:, wind_gust:, sunrise:, sunset:, location_label:, hourly: [%{forecast_time:, temp:, feels_like:, pop:, humidity:, wind_speed:, icon:, condition:}]}}` or `{:error, reason}`. `Weather.fetch_daily/4` returns `{:ok, [%{forecast_date:, high:, low:, pop:, summary:, humidity:, wind_speed:, sunrise:, sunset:, icon:, condition:}]}` or `{:error, :no_daily}`.

- [ ] **Step 1: Write the failing tests**

Replace the full contents of `test/family_dashboard/weather_test.exs`:

```elixir
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
          "weather" => if(rem(i, 2) == 0, do: nil, else: [%{"icon" => "10d", "description" => "light rain"}])
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/weather_test.exs`
Expected: FAIL — current code returns `r.forecast["hourly"]`-shaped data and doesn't set `r.humidity`/etc.

- [ ] **Step 3: Rewrite the implementation**

Replace the full contents of `lib/family_dashboard/weather.ex`:

```elixir
defmodule FamilyDashboard.Weather do
  @moduledoc """
  Facade around the OpenWeatherMap **One Call API 4.0**. Each refresh makes three
  independent calls:

    * `/data/4.0/onecall/current`      — current conditions (authoritative)
    * `/data/4.0/onecall/timeline/1h`  — hourly forecast (next 8 hours)
    * `/data/4.0/onecall/timeline/1day`— daily forecast (next 7 days)

  `fetch/4` returns a map shaped for `FamilyDashboard.WeatherReading` (plus a
  nested `:hourly` list shaped for `FamilyDashboard.WeatherHourly`). The hourly
  and daily calls are best-effort — a slow/failing forecast endpoint drops that
  section rather than failing the whole refresh. The rest of the app depends only
  on this module, never on OpenWeatherMap's HTTP shape. Unix timestamps are
  converted to `DateTime` at this boundary, so nothing downstream ever calls
  `DateTime.from_unix!/1`.

  Note: One Call API 4.0 requires the "One Call by Call" subscription on the
  account tied to `WEATHER_API_KEY`.
  """

  @base_url "https://api.openweathermap.org"
  @current_path "/data/4.0/onecall/current"
  @hourly_path "/data/4.0/onecall/timeline/1h"
  @daily_path "/data/4.0/onecall/timeline/1day"

  @hours 8
  @days 7
  # Timeouts bound how long a slow timeline can stall the worker. The daily
  # endpoint is genuinely slow (OWM often takes ~15-21s to return populated data),
  # so it gets a much longer budget than the fast hourly call.
  @hourly_timeout 8_000
  # The daily endpoint is intermittent (fast when it works, hangs otherwise);
  # cap each attempt and try twice, so the worst case is bounded (~2 x 15s).
  @daily_timeout 15_000
  @daily_attempts 2

  @doc """
  Fetches current conditions + the hourly forecast for `lat`/`lon`. The daily
  forecast is fetched separately (`fetch_daily/4`) because that endpoint is slow
  and flaky. Extra `opts` are forwarded to `Req.get/2` (e.g. a `:plug` stub in
  tests). Returns `{:ok, reading_attrs}` (reading scalars + a `:hourly` list, no
  daily fields) or `{:error, reason}`.
  """
  @spec fetch(number(), number(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    with {:ok, current} <- get(@current_path, params, opts) do
      hourly = best_effort(@hourly_path, params, opts, @hourly_timeout)
      {:ok, normalize_current(current, hourly)}
    end
  end

  @doc """
  Fetches just the 7-day forecast. Retries a couple times because OWM's daily
  endpoint intermittently hangs or returns an empty `data` array. Returns
  `{:ok, days}` (a non-empty list of day attr maps shaped for
  `FamilyDashboard.WeatherDaily`) or `{:error, :no_daily}`.
  """
  @spec fetch_daily(number(), number(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_daily}
  def fetch_daily(lat, lon, units, opts \\ []) do
    params = [lat: lat, lon: lon, units: units, appid: api_key()]

    case best_effort_daily(params, opts, @daily_attempts) do
      %{"data" => [_ | _]} = body -> {:ok, daily_summary(body)}
      _ -> {:error, :no_daily}
    end
  end

  defp best_effort_daily(_params, _opts, 0), do: %{}

  defp best_effort_daily(params, opts, attempts) do
    body = best_effort(@daily_path, params, opts, @daily_timeout)

    if (body["data"] || []) == [] do
      best_effort_daily(params, opts, attempts - 1)
    else
      body
    end
  end

  defp get(path, params, opts) do
    # `compressed: false` is REQUIRED: OWM's One Call timeline endpoints hang/return
    # empty when gzip is requested (curl works because it doesn't ask for gzip).
    # No per-request retry — Oban owns retries at the job level.
    base = [
      base_url: @base_url,
      url: path,
      params: params,
      retry: false,
      compressed: false
    ]

    case Req.get(Keyword.merge(base, opts)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp best_effort(path, params, opts, timeout) do
    opts = Keyword.put_new(opts, :receive_timeout, timeout)

    case get(path, params, opts) do
      {:ok, body} -> body
      {:error, _} -> %{}
    end
  end

  defp normalize_current(current, hourly) do
    obs = (current["data"] || []) |> List.first() || %{}
    weather = (obs["weather"] || []) |> List.first() || %{}
    now = obs["dt"] || 0

    %{
      observed_at: unix_to_datetime(obs["dt"]),
      temp: obs["temp"],
      feels_like: obs["feels_like"],
      condition: weather["description"] || weather["main"],
      icon: weather["icon"],
      humidity: obs["humidity"],
      pressure: obs["pressure"],
      dew_point: obs["dew_point"],
      uvi: obs["uvi"],
      clouds: obs["clouds"],
      visibility: obs["visibility"],
      wind_speed: obs["wind_speed"],
      wind_deg: obs["wind_deg"],
      wind_gust: obs["wind_gust"],
      sunrise: unix_to_datetime(obs["sunrise"]),
      sunset: unix_to_datetime(obs["sunset"]),
      # 4.0 current returns no place name; the dashboard uses Setting.city_label.
      location_label: nil,
      hourly: hourly_summary(hourly, now)
    }
  end

  # Next @hours forecast hours from now.
  defp hourly_summary(hourly, now) do
    (hourly["data"] || [])
    |> Enum.filter(&((&1["dt"] || 0) >= now))
    |> Enum.take(@hours)
    |> Enum.map(fn hour ->
      weather = (hour["weather"] || []) |> List.first()

      %{
        forecast_time: unix_to_datetime(hour["dt"]),
        temp: hour["temp"],
        feels_like: hour["feels_like"],
        pop: hour["pop"],
        humidity: hour["humidity"],
        wind_speed: hour["wind_speed"],
        icon: icon(weather),
        condition: condition(weather)
      }
    end)
  end

  # The first @days forecast days (the endpoint returns forward-looking data from
  # now). Daily `temp` is a min/max object; `weather` may be null → nil icon/condition.
  defp daily_summary(body) do
    (body["data"] || [])
    |> Enum.take(@days)
    |> Enum.map(fn day ->
      temp = day["temp"] || %{}
      weather = (day["weather"] || []) |> List.first()

      %{
        forecast_date: unix_to_datetime(day["dt"]),
        high: temp["max"],
        low: temp["min"],
        pop: day["pop"],
        summary: day["summary"],
        humidity: day["humidity"],
        wind_speed: day["wind_speed"],
        sunrise: unix_to_datetime(day["sunrise"]),
        sunset: unix_to_datetime(day["sunset"]),
        icon: icon(weather),
        condition: condition(weather)
      }
    end)
  end

  defp icon(nil), do: nil
  defp icon(%{"icon" => icon}), do: icon
  defp icon(_), do: nil

  defp condition(nil), do: nil
  defp condition(%{"description" => d}), do: d
  defp condition(%{"main" => m}), do: m
  defp condition(_), do: nil

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  defp api_key, do: Application.get_env(:family_dashboard, :openweather_api_key)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/weather_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/weather.ex test/family_dashboard/weather_test.exs
git commit -m "Return structured hourly/daily weather attrs instead of a raw forecast map"
```

---

### Task 3: Rewrite Sync to persist the normalized weather schema

**Files:**
- Modify: `lib/family_dashboard/sync.ex`
- Test: `test/family_dashboard/sync_test.exs` (only the `refresh_weather/1` and `refresh_daily/1` describe blocks change; the `sync_calendar/2` describe block is untouched)

**Interfaces:**
- Consumes: `Weather.fetch/4` and `Weather.fetch_daily/4` from Task 2 (structured attrs with a `:hourly` key / list of day attrs). `Dashboard.create_weather_hourly!/1`, `Dashboard.create_weather_daily!/1`, `Dashboard.latest_weather/0` (now loads `.hourly`/`.daily`) from Task 1.
- Produces: `Sync.refresh_weather/1` and `Sync.refresh_daily/1` — same public signatures and return values (`:ok | {:error, reason}`) as before; only the persistence internals change. Carry-forward model: each fast refresh creates a new `WeatherReading` + its `WeatherHourly` rows, and copies the previous reading's `WeatherDaily` rows forward (so the 7-day widget stays populated between the less-frequent daily job's runs); the daily job replaces the latest reading's `WeatherDaily` rows in place.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/sync_test.exs`, replace the `describe "refresh_weather/1"` and `describe "refresh_daily/1"` blocks (everything from `describe "refresh_weather/1" do` to the file's closing `end`) with:

```elixir
  describe "refresh_weather/1" do
    defp weather_plug do
      current = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => 70.0,
            "feels_like" => 68.0,
            "weather" => [%{"description" => "clear sky", "icon" => "01d"}]
          }
        ]
      }

      hourly = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => 70.0,
            "pop" => 0.0,
            "weather" => [%{"icon" => "01d"}]
          }
        ]
      }

      daily = %{
        "data" => [
          %{
            "dt" => 1_783_000_000,
            "temp" => %{"min" => 60.0, "max" => 80.0},
            "weather" => [%{"icon" => "01d"}]
          }
        ]
      }

      fn conn ->
        case conn.request_path do
          "/data/4.0/onecall/current" -> Req.Test.json(conn, current)
          "/data/4.0/onecall/timeline/1h" -> Req.Test.json(conn, hourly)
          "/data/4.0/onecall/timeline/1day" -> Req.Test.json(conn, daily)
        end
      end
    end

    test "records a reading (with hourly rows) and broadcasts when a location is configured" do
      Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")

      assert :ok = Sync.refresh_weather(plug: weather_plug())

      assert_receive :weather_updated
      reading = Dashboard.latest_weather!()
      assert reading.temp == 70.0
      assert reading.condition == "clear sky"
      assert length(reading.hourly) == 1
      assert List.first(reading.hourly).temp == 70.0
    end

    test "the current+hourly refresh does not fetch daily data" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert Dashboard.latest_weather!().daily == []
    end
  end

  describe "refresh_daily/1" do
    test "patches the latest reading's 7-day and today's high/low" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert Dashboard.latest_weather!().daily == []

      assert :ok = Sync.refresh_daily(plug: weather_plug())

      reading = Dashboard.latest_weather!()
      assert length(reading.daily) == 1
      assert reading.high == 80.0
      assert reading.low == 60.0
      # hourly data is untouched by the daily job
      assert reading.hourly != []
    end

    test "a later current+hourly refresh carries the 7-day forward onto the new reading" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert :ok = Sync.refresh_daily(plug: weather_plug())
      assert length(Dashboard.latest_weather!().daily) == 1

      # New current+hourly reading is a NEW row that carries the last known days
      # + high/low forward, so the widget stays populated between daily runs.
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      reading = Dashboard.latest_weather!()
      assert length(reading.daily) == 1
      assert reading.high == 80.0
    end

    test "returns an error when the daily endpoint has no data" do
      assert :ok = Sync.refresh_weather(plug: weather_plug())
      empty = fn conn -> Req.Test.json(conn, %{"data" => []}) end

      assert {:error, :no_daily} = Sync.refresh_daily(plug: empty)
    end

    test "records a human-readable weather_last_error on a fetch failure" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"message":"Invalid API key"})) end

      assert {:error, {:http_status, 401}} = Sync.refresh_weather(plug: plug)

      {:ok, setting} = Dashboard.current_setting()
      assert setting.weather_last_error =~ "Invalid or inactive API key"
      assert setting.weather_last_attempted_at
    end

    test "clears weather_last_error after a subsequent successful refresh" do
      fail_plug = fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end
      assert {:error, _} = Sync.refresh_weather(plug: fail_plug)
      assert Dashboard.current_setting!().weather_last_error

      assert :ok = Sync.refresh_weather(plug: weather_plug())
      assert is_nil(Dashboard.current_setting!().weather_last_error)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/sync_test.exs`
Expected: FAIL — the current implementation still writes to the (now-removed) `forecast` field.

- [ ] **Step 3: Rewrite the implementation**

In `lib/family_dashboard/sync.ex`, replace the `do_refresh_weather/2` success branch, and the `apply_daily_to_latest/1` and `carry_forward_daily/1` private functions. The full new file:

```elixir
defmodule FamilyDashboard.Sync do
  @moduledoc """
  Orchestrates fetching external data into the dashboard's resources.

  Used by the Oban workers. Kept deliberately transaction-aware:

    * the network fetch happens **before** any DB write, so a transient HTTP
      failure never rolls back a `last_error` write;
    * `last_error` is written in its **own** transaction (the project runs with
      `transaction_rollback_on_error?: true`);
    * PubSub broadcasts fire **after commit**, so a rolled-back sync can't push
      phantom data to the wall display.
  """

  require Ash.Query

  alias FamilyDashboard.{Dashboard, ICal, Weather}

  # How far ahead we materialize occurrences. "Today" plus three weeks.
  @window_days 21

  @doc """
  Syncs one calendar: fetch its feed, then replace its events in the rolling
  window. Returns `:ok`, or `{:error, reason}` (with `last_error` recorded) on a
  fetch failure so Oban can retry.
  """
  @spec sync_calendar(FamilyDashboard.Calendar.t(), keyword()) :: :ok | {:error, term()}
  def sync_calendar(calendar, opts \\ []) do
    from = Date.utc_today()
    to = Date.add(from, @window_days)

    case ICal.fetch_and_expand(calendar.ical_url, from, to, opts) do
      {:ok, occurrences} ->
        replace_window_events(calendar, occurrences, from, to)
        broadcast("events", :events_updated)
        :ok

      {:error, reason} ->
        record_error(calendar, reason)
        {:error, reason}
    end
  end

  @doc """
  Refreshes weather for the configured location. Returns `:ok`, `{:error,
  reason}` on a fetch failure, or `{:error, :no_location}` if unconfigured.
  """
  @spec refresh_weather(keyword()) :: :ok | {:error, term()}
  def refresh_weather(opts \\ []) do
    case Dashboard.current_setting() do
      {:ok, %{} = setting} -> do_refresh_weather(setting, opts)
      # No settings row yet — nothing to fetch or record status against.
      _ -> {:error, :no_location}
    end
  end

  defp do_refresh_weather(setting, opts) do
    cond do
      is_nil(setting.latitude) or is_nil(setting.longitude) ->
        record_weather_status(setting, "No location configured")
        {:error, :no_location}

      is_nil(api_key()) and opts == [] ->
        record_weather_status(setting, "No API key configured (set WEATHER_API_KEY)")
        {:error, :no_api_key}

      true ->
        case Weather.fetch(setting.latitude, setting.longitude, setting.units || "metric", opts) do
          {:ok, attrs} ->
            record_weather(attrs)
            record_weather_status(setting, nil)
            broadcast("weather", :weather_updated)
            :ok

          {:error, reason} ->
            record_weather_status(setting, humanize_weather_error(reason))
            {:error, reason}
        end
    end
  end

  # Creates the new reading + its hourly rows, and copies the previous
  # reading's daily rows (+ high/low) forward so the 7-day widget stays
  # populated between the less-frequent daily job's runs.
  defp record_weather(attrs) do
    {hourly, reading_attrs} = Map.pop(attrs, :hourly, [])
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

  @doc """
  Refreshes just the 7-day forecast — its own (less frequent, higher-retry) Oban
  job because the daily endpoint is slow and flaky. Replaces the latest
  reading's `WeatherDaily` rows and today's high/low in place. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec refresh_daily(keyword()) :: :ok | {:error, term()}
  def refresh_daily(opts \\ []) do
    case Dashboard.current_setting() do
      {:ok, %{latitude: lat, longitude: lon} = setting}
      when not is_nil(lat) and not is_nil(lon) ->
        if is_nil(api_key()) and opts == [] do
          {:error, :no_api_key}
        else
          record_daily_attempt(setting)

          case Weather.fetch_daily(lat, lon, setting.units || "metric", opts) do
            {:ok, days} -> apply_daily_to_latest(days)
            {:error, reason} -> {:error, reason}
          end
        end

      _ ->
        {:error, :no_location}
    end
  end

  # The daily forecast lives on the newest reading (created by the fast
  # current+hourly refresh); replace its WeatherDaily rows + patch today's
  # high/low in place.
  defp apply_daily_to_latest(days) do
    case latest_reading() do
      %{} = reading ->
        today = List.first(days) || %{}

        {:ok, _} =
          FamilyDashboard.Repo.transaction(fn ->
            Enum.each(reading.daily, &Ash.destroy!/1)

            Enum.each(days, fn day ->
              Dashboard.create_weather_daily!(Map.put(day, :weather_reading_id, reading.id))
            end)

            Dashboard.update_weather_reading!(reading, %{high: today[:high], low: today[:low]})
          end)

        broadcast("weather", :weather_updated)
        :ok

      # No reading yet; the next current+hourly refresh creates one and the
      # following daily cycle fills it in.
      nil ->
        {:error, :no_reading}
    end
  end

  defp latest_reading do
    case Dashboard.latest_weather() do
      {:ok, %{} = reading} -> reading
      _ -> nil
    end
  end

  defp record_daily_attempt(setting) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Dashboard.record_weather_status!(setting, %{daily_last_attempted_at: now})
  end

  defp record_weather_status(setting, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Dashboard.record_weather_status!(setting, %{
      weather_last_error: error,
      weather_last_attempted_at: now
    })
  end

  defp humanize_weather_error({:http_status, 401}), do: "Invalid or inactive API key"

  defp humanize_weather_error({:http_status, status}),
    do: "Weather service returned HTTP #{status}"

  defp humanize_weather_error(reason), do: "Weather fetch failed: #{inspect(reason)}"

  defp api_key, do: Application.get_env(:family_dashboard, :openweather_api_key)

  # Upsert the calendar's occurrences in the window, then prune whatever the
  # feed no longer returns (ended recurrences, cancelled/moved occurrences),
  # atomically. Using bang calls means any failure raises and rolls the whole
  # transaction back.
  #
  # Upsert (rather than delete-and-reinsert) keeps a stable row per occurrence
  # across syncs, so an unchanged event never round-trips its `id`/`inserted_at`
  # — but that means removed occurrences no longer disappear "for free"; the
  # explicit prune step below restores that self-cleaning property.
  defp replace_window_events(calendar, occurrences, from, to) do
    from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(to, ~T[23:59:59], "Etc/UTC")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      FamilyDashboard.Repo.transaction(fn ->
        kept_ids =
          Enum.map(occurrences, fn occ ->
            Dashboard.create_event!(%{
              calendar_id: calendar.id,
              uid: occ.uid,
              title: occ.title,
              starts_at: occ.starts_at,
              ends_at: occ.ends_at,
              all_day: occ.all_day?,
              location: occ.location
            }).id
          end)

        # Ash resolves both `id in []` and `not (id in [])` to "match nothing" —
        # so an `id not in ^kept_ids` filter with an empty list would silently
        # prune zero rows instead of the whole window. Branch explicitly
        # instead of relying on that.
        prune_query =
          FamilyDashboard.Event
          |> Ash.Query.filter(
            calendar_id == ^calendar.id and starts_at >= ^from_dt and starts_at <= ^to_dt
          )

        prune_query =
          if kept_ids == [] do
            prune_query
          else
            Ash.Query.filter(prune_query, id not in ^kept_ids)
          end

        Ash.bulk_destroy!(prune_query, :destroy, %{}, strategy: [:stream])

        Dashboard.update_calendar!(calendar, %{
          last_synced_at: now,
          last_attempted_at: now,
          last_error: nil
        })
      end)

    :ok
  end

  defp record_error(calendar, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Dashboard.update_calendar!(calendar, %{last_attempted_at: now, last_error: inspect(reason)})
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(FamilyDashboard.PubSub, topic, message)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/sync_test.exs`
Expected: PASS (all describe blocks, including the untouched `sync_calendar/2` ones).

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/sync.ex test/family_dashboard/sync_test.exs
git commit -m "Persist normalized hourly/daily weather rows in Sync, with carry-forward on refresh"
```

---

### Task 4: Update the public dashboard's weather read path

**Files:**
- Modify: `lib/family_dashboard_web/live/dashboard_live.ex`

**Interfaces:**
- Consumes: `@weather.hourly` (list of `WeatherHourly` structs, ascending), `@weather.daily` (list of `WeatherDaily` structs, ascending) from Task 1/3 — replaces `@weather.forecast["hourly"]`/`["days"]`.

No test changes are needed: `test/family_dashboard_web/live/dashboard_live_test.exs` only asserts on greeting/agenda/error text and never touches forecast shape — confirm this after Step 2.

- [ ] **Step 1: Run the existing dashboard tests to confirm the current (pre-change) baseline**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: FAIL at this point in the sequence — `@weather.forecast` no longer exists (Task 1 already dropped that column), so the template crashes. This confirms Task 4 is the fix needed; there's no separate "write a failing test" step because the existing suite already fails for the right reason.

- [ ] **Step 2: Update the 8-hour forecast section**

In `lib/family_dashboard_web/live/dashboard_live.ex`, replace the `<!-- 8-hour forecast -->` section:

```heex
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
                </div>
              </div>
            </div>
          </section>
```

- [ ] **Step 3: Update the 7-day forecast section**

Replace the `<!-- 7-day forecast -->` section:

```heex
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
                  <span class="text-lg font-semibold">{day_short_label(day.forecast_date, @tz, @today)}</span>
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
```

- [ ] **Step 4: Update the presentation helpers**

Replace `hourly_temps/1`, `daily_days/1`, `daily_temp_bounds/1`:

```elixir
  defp hourly_temps(nil), do: []
  defp hourly_temps(weather), do: weather.hourly |> Enum.map(& &1.temp)

  defp daily_days(nil), do: []
  defp daily_days(weather), do: weather.daily
```

```elixir
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
```

Replace `hourly_bar_style/3`, `daily_range_style/3`, `daily_avg_marker_style/3`, `day_average/1`:

```elixir
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
```

Replace `hour_number/2`, `hour_meridiem/2`, `day_short_label/3` (they now receive a `DateTime`, not a unix integer, so drop the `DateTime.from_unix!/1` step):

```elixir
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

  defp day_short_label(nil, _tz, _today), do: ""

  defp day_short_label(dt, tz, today) do
    date = dt |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    if date == today, do: "Today", else: Calendar.strftime(date, "%a")
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/dashboard_live_test.exs`
Expected: PASS

Run the full suite once to confirm nothing else broke: `mix test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/family_dashboard_web/live/dashboard_live.ex
git commit -m "Read the wall display's forecast widgets from the normalized weather associations"
```

---

### Task 5: relative_time/1 helper

**Files:**
- Modify: `lib/family_dashboard_web/components/core_components.ex`
- Test: `test/family_dashboard_web/components/core_components_test.exs` (new)

**Interfaces:**
- Produces: `FamilyDashboardWeb.CoreComponents.relative_time/1` — `nil -> "never"`, `< 60s -> "just now"`, else `"Nm ago"` / `"Nh ago"` / `"Nd ago"`. Used by `OpsLive` (Task 7) for the sync-status panel.

- [ ] **Step 1: Write the failing test**

Create `test/family_dashboard_web/components/core_components_test.exs`:

```elixir
defmodule FamilyDashboardWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import FamilyDashboardWeb.CoreComponents, only: [relative_time: 1]

  describe "relative_time/1" do
    test "nil is never" do
      assert relative_time(nil) == "never"
    end

    test "under a minute is just now" do
      assert relative_time(DateTime.utc_now()) == "just now"
    end

    test "minutes ago" do
      dt = DateTime.utc_now() |> DateTime.add(-5, :minute)
      assert relative_time(dt) == "5m ago"
    end

    test "hours ago" do
      dt = DateTime.utc_now() |> DateTime.add(-3, :hour)
      assert relative_time(dt) == "3h ago"
    end

    test "days ago" do
      dt = DateTime.utc_now() |> DateTime.add(-2, :day)
      assert relative_time(dt) == "2d ago"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/family_dashboard_web/components/core_components_test.exs`
Expected: FAIL with "function relative_time/1 is undefined"

- [ ] **Step 3: Add the implementation**

In `lib/family_dashboard_web/components/core_components.ex`, add this function after the `icon/1` function definition (before the `## JS Commands` section):

```elixir
  @doc """
  A short, human relative-time string for a UTC datetime — `"never"` when nil,
  `"just now"` under a minute, then minutes/hours/days ago. Used by the ops
  hub's sync-status panel; pure and independent of any particular time zone
  (unlike the wall display, an admin page can show UTC-relative deltas).
  """
  @spec relative_time(DateTime.t() | nil) :: String.t()
  def relative_time(nil), do: "never"

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/family_dashboard_web/components/core_components_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard_web/components/core_components.ex test/family_dashboard_web/components/core_components_test.exs
git commit -m "Add a relative_time/1 helper for the ops hub's sync-status panel"
```

---

### Task 6: Heartbeat force-capable enqueue helpers

**Files:**
- Modify: `lib/family_dashboard/heartbeat.ex`
- Test: `test/family_dashboard/heartbeat_test.exs` (add a new describe block; existing tests are unchanged and must keep passing)

**Interfaces:**
- Produces: `Heartbeat.enqueue_weather/1`, `Heartbeat.enqueue_daily/1`, `Heartbeat.enqueue_calendar/3` (all `def`, default `force? = false`). `force?: true` passes `unique: false` to the worker's `.new/2`, bypassing that worker's Oban uniqueness window so a manual trigger always enqueues. Used directly by `OpsLive` in Task 8.

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard/heartbeat_test.exs`, add this describe block at the end of the module, before the final `end`:

```elixir
  describe "enqueue_weather/1, enqueue_daily/1, enqueue_calendar/3 — force bypass" do
    test "enqueue_weather(false) is de-duped by the worker's unique window" do
      Heartbeat.enqueue_weather()
      Heartbeat.enqueue_weather()
      assert [_one] = all_enqueued(worker: WeatherRefresh)
    end

    test "enqueue_weather(true) enqueues even when a job is already pending" do
      Heartbeat.enqueue_weather()
      Heartbeat.enqueue_weather(true)
      assert [_one, _two] = all_enqueued(worker: WeatherRefresh)
    end

    test "enqueue_daily(true) enqueues even when a job is already pending" do
      Heartbeat.enqueue_daily()
      Heartbeat.enqueue_daily(true)
      assert [_one, _two] = all_enqueued(worker: WeatherDailyRefresh)
    end

    test "enqueue_calendar(id, attempts, true) enqueues even when a job is already pending" do
      cal = Dashboard.create_calendar!(%{name: "Fam", ical_url: "https://x/cal.ics"})

      Heartbeat.enqueue_calendar(cal.id, 3)
      Heartbeat.enqueue_calendar(cal.id, 3, true)

      assert [_one, _two] = all_enqueued(worker: CalendarSync, args: %{calendar_id: cal.id})
    end
  end
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `mix test test/family_dashboard/heartbeat_test.exs`
Expected: FAIL with "function enqueue_weather/0 is undefined" (etc.) — these public functions don't exist yet.

- [ ] **Step 3: Rewrite the implementation**

Replace the full contents of `lib/family_dashboard/heartbeat.ex`:

```elixir
defmodule FamilyDashboard.Heartbeat do
  @moduledoc """
  The fixed-cadence tick (driven by an ash_oban scheduled action every minute).

  It reads the live `Setting` row and enqueues sync work only for what is
  actually *due* per the configured intervals — so the effective sync cadence
  and retry count are editable in the settings panel without a redeploy.

  `enqueue_weather/1`, `enqueue_daily/1`, and `enqueue_calendar/3` are also used
  directly by the ops hub's manual "sync now" buttons (`force?: true`), which
  bypass each worker's Oban uniqueness window so a click always enqueues even
  if a job is already pending — see `FamilyDashboardWeb.OpsLive`.
  """

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}

  # Fallbacks when the singleton Setting row hasn't been created yet.
  @default_calendar_minutes 15
  @default_weather_minutes 30
  @default_daily_minutes 60
  @default_max_attempts 3

  @spec run() :: :ok
  def run do
    setting = current_setting()
    now = DateTime.utc_now()

    enqueue_due_calendars(setting, now)
    enqueue_weather_if_due(setting, now)
    enqueue_daily_if_due(setting, now)
    :ok
  end

  @doc "Enqueues a weather refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_weather(boolean()) :: :ok
  def enqueue_weather(force? \\ false) do
    # max_attempts: 1 — weather is ephemeral; a failed fetch waits for the next
    # cycle rather than retrying in-cycle and burning the API quota.
    opts = [max_attempts: 1] ++ force_opts(force?)
    %{} |> WeatherRefresh.new(opts) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a daily-forecast refresh. `force?: true` bypasses the worker's unique window."
  @spec enqueue_daily(boolean()) :: :ok
  def enqueue_daily(force? \\ false) do
    %{} |> WeatherDailyRefresh.new(force_opts(force?)) |> Oban.insert()
    :ok
  end

  @doc "Enqueues a sync for one calendar. `force?: true` bypasses the worker's unique window."
  @spec enqueue_calendar(String.t(), pos_integer(), boolean()) :: :ok
  def enqueue_calendar(calendar_id, max_attempts, force? \\ false) do
    opts = [max_attempts: max_attempts] ++ force_opts(force?)
    %{calendar_id: calendar_id} |> CalendarSync.new(opts) |> Oban.insert()
    :ok
  end

  # `unique: false` on `.new/2` bypasses the worker's compile-time unique clause
  # for this single insert, so a manual click always enqueues instead of being
  # silently absorbed by a pending/executing job's uniqueness window.
  defp force_opts(true), do: [unique: false]
  defp force_opts(false), do: []

  defp enqueue_due_calendars(setting, now) do
    interval = minutes(setting, :calendar_sync_minutes, @default_calendar_minutes) * 60
    max_attempts = attempts(setting)

    Dashboard.list_calendars!()
    |> Enum.filter(& &1.active)
    |> Enum.filter(&calendar_due?(&1, now, interval))
    |> Enum.each(&enqueue_calendar(&1.id, max_attempts))
  end

  # No setting row yet — nothing to fetch or record status against.
  defp enqueue_weather_if_due(nil, _now), do: :ok

  defp enqueue_weather_if_due(setting, now) do
    interval = minutes(setting, :weather_refresh_minutes, @default_weather_minutes) * 60

    if weather_due?(setting.weather_last_attempted_at, now, interval) do
      enqueue_weather()
    end
  end

  # The 7-day forecast refreshes on its own, less frequent schedule (the worker
  # itself retries the flaky endpoint).
  defp enqueue_daily_if_due(nil, _now), do: :ok

  defp enqueue_daily_if_due(setting, now) do
    interval = minutes(setting, :daily_refresh_minutes, @default_daily_minutes) * 60

    if weather_due?(setting.daily_last_attempted_at, now, interval) do
      enqueue_daily()
    end
  end

  # Gate on the last *attempt* (success or failure) so a broken feed is retried
  # on its interval, not re-enqueued every minute.
  defp calendar_due?(%{last_attempted_at: nil}, _now, _interval), do: true

  defp calendar_due?(%{last_attempted_at: last_attempted_at}, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  # Gate on the last *attempt* (success or failure), not the last successful
  # reading — otherwise a persistently-failing fetch is "due" every minute and
  # hammers the API.
  defp weather_due?(nil, _now, _interval), do: true

  defp weather_due?(last_attempted_at, now, interval) do
    DateTime.diff(now, last_attempted_at) >= interval
  end

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  defp minutes(nil, _key, default), do: default
  defp minutes(setting, key, default), do: Map.get(setting, key) || default

  defp attempts(nil), do: @default_max_attempts
  defp attempts(setting), do: setting.sync_max_attempts || @default_max_attempts
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/heartbeat_test.exs`
Expected: PASS — both the new describe block and the pre-existing `run/0` tests (unchanged behavior, just refactored to share the new public helpers).

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/heartbeat.ex test/family_dashboard/heartbeat_test.exs
git commit -m "Extract force-capable enqueue helpers from Heartbeat for manual sync triggers"
```

---

### Task 7: OpsLive — route, mount, sync-status panel

**Files:**
- Create: `lib/family_dashboard_web/live/ops_live.ex`
- Modify: `lib/family_dashboard_web/router.ex`
- Test: `test/family_dashboard_web/live/ops_live_test.exs` (new)

**Interfaces:**
- Consumes: `Dashboard.list_calendars!/0`, `Dashboard.current_setting/0`, `CoreComponents.relative_time/1` (Task 5).
- Produces: route `~p"/ops"` → `FamilyDashboardWeb.OpsLive`, gated by `:settings_area`. Assigns `@calendars` (list of `Calendar` structs) and `@setting` (`Setting` struct or nil) used by Task 8 and Task 13.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard_web/live/ops_live_test.exs`:

```elixir
defmodule FamilyDashboardWeb.OpsLiveTest do
  use FamilyDashboardWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FamilyDashboard.Dashboard

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  defp authed(conn), do: put_req_header(conn, "authorization", @auth)

  test "requires the settings password", %{conn: conn} do
    conn = get(conn, "/ops")
    assert conn.status == 401
  end

  test "renders the status panel with the seeded setting and no calendars", %{conn: conn} do
    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Ops"
    assert html =~ "last attempted never"
  end

  test "lists a calendar with its sync status", %{conn: conn} do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "Family"
    assert html =~ "synced never"
  end

  test "shows a calendar's last_error in red", %{conn: conn} do
    cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
    Dashboard.update_calendar!(cal, %{last_error: "boom"})

    {:ok, _live, html} = conn |> authed() |> live(~p"/ops")

    assert html =~ "boom"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: FAIL — no route/module exists yet (404 / compile error).

- [ ] **Step 3: Add the route**

In `lib/family_dashboard_web/router.ex`, inside the existing `scope "/" do pipe_through [:browser, :settings_area]` block, add a line after `oban_dashboard("/oban")`:

```elixir
  scope "/" do
    pipe_through [:browser, :settings_area]

    ash_admin "/admin"
    oban_dashboard("/oban")
    live "/ops", FamilyDashboardWeb.OpsLive, :index
  end
```

- [ ] **Step 4: Create OpsLive**

Create `lib/family_dashboard_web/live/ops_live.ex`:

```elixir
defmodule FamilyDashboardWeb.OpsLive do
  @moduledoc """
  The ops hub: manual sync triggers, a sync-status health panel, and
  calendars/settings backup & restore. Password-gated (same `:settings_area`
  pipeline as `/admin` and `/oban`) — this is an operator page, not the wall
  display, so normal interactive sizing applies rather than the dashboard's
  wall-scale type.

  Unlike `DashboardLive`, the initial data load only runs on the *connected*
  mount, not the disconnected dead render — the dead render just shows an
  empty shell, avoiding a duplicate DB read on every page load.
  """
  use FamilyDashboardWeb, :live_view

  import FamilyDashboardWeb.CoreComponents, only: [relative_time: 1]

  alias FamilyDashboard.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
        reload_status(socket)
      else
        assign(socket, calendars: [], setting: nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:weather_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:events_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:reload_status, socket), do: {:noreply, reload_status(socket)}

  defp reload_status(socket) do
    assign(socket, calendars: Dashboard.list_calendars!(), setting: current_setting())
  end

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-3xl mx-auto p-6 flex flex-col gap-6">
        <.header>Ops</.header>

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Weather</h2>
            <p :if={@setting} class="text-sm text-base-content/70">
              Current+hourly last attempted {relative_time(@setting.weather_last_attempted_at)}
            </p>
            <p :if={@setting && @setting.weather_last_error} class="text-error text-sm">
              {@setting.weather_last_error}
            </p>
            <p :if={@setting} class="text-sm text-base-content/70">
              7-day last attempted {relative_time(@setting.daily_last_attempted_at)}
            </p>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Calendars</h2>
            <ul class="list">
              <li :for={cal <- @calendars} class="list-row">
                <div class="list-col-grow">
                  <div class="font-bold">
                    {cal.name}
                    <span class={[
                      "badge badge-sm",
                      cal.active && "badge-success",
                      !cal.active && "badge-ghost"
                    ]}>
                      {if cal.active, do: "active", else: "inactive"}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    synced {relative_time(cal.last_synced_at)}
                  </div>
                  <div :if={cal.last_error} class="text-sm text-error">{cal.last_error}</div>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/family_dashboard_web/live/ops_live.ex lib/family_dashboard_web/router.ex test/family_dashboard_web/live/ops_live_test.exs
git commit -m "Add the /ops hub with a sync-status panel"
```

---

### Task 8: OpsLive — manual sync trigger buttons

**Files:**
- Modify: `lib/family_dashboard_web/live/ops_live.ex`
- Modify: `test/family_dashboard_web/live/ops_live_test.exs`

**Interfaces:**
- Consumes: `Heartbeat.enqueue_weather/1`, `Heartbeat.enqueue_daily/1`, `Heartbeat.enqueue_calendar/3` (Task 6).

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard_web/live/ops_live_test.exs`, add `use Oban.Testing, repo: FamilyDashboard.Repo` and an alias right after the `use FamilyDashboardWeb.ConnCase` line, and append a new describe block. The top of the file and the new block:

```elixir
defmodule FamilyDashboardWeb.OpsLiveTest do
  use FamilyDashboardWeb.ConnCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  import Phoenix.LiveViewTest

  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Workers.{CalendarSync, WeatherDailyRefresh, WeatherRefresh}

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  defp authed(conn), do: put_req_header(conn, "authorization", @auth)

  # ...(existing tests unchanged)...

  describe "manual triggers" do
    test "refresh_weather enqueues WeatherRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_weather")

      assert_enqueued(worker: WeatherRefresh)
    end

    test "refresh_weather always enqueues, even with a job already pending (force bypass)", %{
      conn: conn
    } do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_weather")
      render_click(live, "refresh_weather")

      assert [_one, _two] = all_enqueued(worker: WeatherRefresh)
    end

    test "refresh_daily enqueues WeatherDailyRefresh", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "refresh_daily")

      assert_enqueued(worker: WeatherDailyRefresh)
    end

    test "sync_calendar enqueues CalendarSync for the matching id", %{conn: conn} do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      live |> element("button[phx-value-id='#{cal.id}']") |> render_click()

      assert_enqueued(worker: CalendarSync, args: %{calendar_id: cal.id})
    end

    test "sync_calendar ignores an unknown id", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "sync_calendar", %{"id" => Ash.UUID.generate()})

      refute_enqueued(worker: CalendarSync)
    end

    test "sync_all_calendars enqueues only active calendars", %{conn: conn} do
      active = Dashboard.create_calendar!(%{name: "On", ical_url: "https://x/on.ics"})
      Dashboard.create_calendar!(%{name: "Off", ical_url: "https://x/off.ics", active: false})

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "sync_all_calendars")

      assert_enqueued(worker: CalendarSync, args: %{calendar_id: active.id})
      assert [_one] = all_enqueued(worker: CalendarSync)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: FAIL — the buttons/events don't exist yet.

- [ ] **Step 3: Add the buttons and handlers**

In `lib/family_dashboard_web/live/ops_live.ex`, add `alias FamilyDashboard.Heartbeat` next to the existing `alias FamilyDashboard.Dashboard`. Update the weather `<section>` in `render/1` to add buttons:

```heex
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Weather</h2>
            <p :if={@setting} class="text-sm text-base-content/70">
              Current+hourly last attempted {relative_time(@setting.weather_last_attempted_at)}
            </p>
            <p :if={@setting && @setting.weather_last_error} class="text-error text-sm">
              {@setting.weather_last_error}
            </p>
            <p :if={@setting} class="text-sm text-base-content/70">
              7-day last attempted {relative_time(@setting.daily_last_attempted_at)}
            </p>
            <div class="flex gap-2 mt-2">
              <.button phx-click="refresh_weather">Refresh weather now</.button>
              <.button phx-click="refresh_daily">Refresh 7-day now</.button>
            </div>
          </div>
        </section>
```

Update the calendars `<section>` to add a header button and a per-row button:

```heex
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">Calendars</h2>
              <.button phx-click="sync_all_calendars">Sync all active</.button>
            </div>
            <ul class="list">
              <li :for={cal <- @calendars} class="list-row">
                <div class="list-col-grow">
                  <div class="font-bold">
                    {cal.name}
                    <span class={[
                      "badge badge-sm",
                      cal.active && "badge-success",
                      !cal.active && "badge-ghost"
                    ]}>
                      {if cal.active, do: "active", else: "inactive"}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    synced {relative_time(cal.last_synced_at)}
                  </div>
                  <div :if={cal.last_error} class="text-sm text-error">{cal.last_error}</div>
                </div>
                <.button phx-click="sync_calendar" phx-value-id={cal.id}>Sync now</.button>
              </li>
            </ul>
          </div>
        </section>
```

Add `handle_event/3` clauses, after `handle_info/2` and before `reload_status/1`:

```elixir
  @impl true
  def handle_event("refresh_weather", _params, socket) do
    Heartbeat.enqueue_weather(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "Weather refresh queued.")}
  end

  def handle_event("refresh_daily", _params, socket) do
    Heartbeat.enqueue_daily(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "7-day forecast refresh queued.")}
  end

  def handle_event("sync_calendar", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.calendars, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown calendar.")}

      calendar ->
        Heartbeat.enqueue_calendar(calendar.id, max_attempts(socket.assigns.setting), true)
        schedule_status_reload()
        {:noreply, put_flash(socket, :info, "Sync queued for #{calendar.name}.")}
    end
  end

  def handle_event("sync_all_calendars", _params, socket) do
    active = Enum.filter(socket.assigns.calendars, & &1.active)
    max_attempts = max_attempts(socket.assigns.setting)

    Enum.each(active, &Heartbeat.enqueue_calendar(&1.id, max_attempts, true))
    schedule_status_reload()

    {:noreply, put_flash(socket, :info, "Queued #{length(active)} calendar(s).")}
  end

  # Success re-loads the panel via the PubSub handlers above, but a fetch
  # *failure* records status without broadcasting — this delayed reload
  # catches that case too, so an errored manual trigger still shows up.
  defp schedule_status_reload, do: Process.send_after(self(), :reload_status, 2_000)

  defp max_attempts(nil), do: 3
  defp max_attempts(setting), do: setting.sync_max_attempts || 3
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard_web/live/ops_live.ex test/family_dashboard_web/live/ops_live_test.exs
git commit -m "Add manual sync trigger buttons to the ops hub"
```

---

### Task 9: Calendar upsert-by-id action

This must land before the Backup module (Task 10), which calls `Dashboard.upsert_calendar!/1`.

**Files:**
- Modify: `lib/family_dashboard/calendar.ex`
- Modify: `lib/family_dashboard/dashboard.ex`
- Test: `test/family_dashboard/calendar_test.exs` (new)
- Generated: `priv/repo/migrations/<timestamp>_calendar_upsert_identity.exs`, updated `priv/resource_snapshots/repo/calendars/*`

**Interfaces:**
- Produces: `Dashboard.upsert_calendar/1,!/1` — creates a calendar if `id` doesn't exist, updates `name`/`ical_url`/`color`/`active` in place if it does. Never touches `last_synced_at`/`last_attempted_at`/`last_error` on an existing row.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/calendar_test.exs`:

```elixir
defmodule FamilyDashboard.CalendarTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  describe "upsert action (used by FamilyDashboard.Backup to restore calendars)" do
    test "creates a calendar when the id doesn't exist yet" do
      id = Ash.UUID.generate()

      assert {:ok, cal} =
               Dashboard.upsert_calendar(%{id: id, name: "New", ical_url: "https://x/n.ics"})

      assert cal.id == id
      assert cal.name == "New"
    end

    test "updates the existing row in place when the id already exists" do
      cal = Dashboard.create_calendar!(%{name: "Old", ical_url: "https://x/old.ics"})

      assert {:ok, updated} =
               Dashboard.upsert_calendar(%{
                 id: cal.id,
                 name: "New name",
                 ical_url: "https://x/new.ics"
               })

      assert updated.id == cal.id
      assert updated.name == "New name"
      assert Dashboard.list_calendars!() |> length() == 1
    end

    test "does not clobber sync-status fields on an existing row" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      synced_at = DateTime.utc_now() |> DateTime.truncate(:second)
      Dashboard.update_calendar!(cal, %{last_synced_at: synced_at})

      assert {:ok, updated} =
               Dashboard.upsert_calendar(%{
                 id: cal.id,
                 name: "Family",
                 ical_url: "https://x/cal.ics"
               })

      assert updated.last_synced_at == synced_at
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/calendar_test.exs`
Expected: FAIL — `Dashboard.upsert_calendar/1` is undefined.

- [ ] **Step 3: Add the identity and upsert action**

In `lib/family_dashboard/calendar.ex`, add the `create :upsert` action inside `actions do ... end` (after the existing `defaults [...]` call) and an `identities do ... end` block after `attributes do ... end` (matching the section order in `lib/family_dashboard/event.ex`). Full file:

```elixir
defmodule FamilyDashboard.Calendar do
  use Ash.Resource,
    otp_app: :family_dashboard,
    domain: FamilyDashboard.Dashboard,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "calendars"
    repo FamilyDashboard.Repo
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :name,
        :ical_url,
        :color,
        :active,
        :last_synced_at,
        :last_attempted_at,
        :last_error
      ],
      update: [
        :name,
        :ical_url,
        :color,
        :active,
        :last_synced_at,
        :last_attempted_at,
        :last_error
      ]
    ]

    # Used by FamilyDashboard.Backup to restore calendars from a JSON export:
    # updates an existing row by id (leaving its sync-status fields alone —
    # Backup resets those separately, in its own follow-up call) or inserts a
    # new one. Never touches a calendar that isn't present in the backup.
    create :upsert do
      upsert? true
      upsert_identity :id
      upsert_fields [:name, :ical_url, :color, :active]
      accept [:id, :name, :ical_url, :color, :active]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :ical_url, :string do
      allow_nil? false
      public? true
    end

    attribute :color, :string do
      public? true
    end

    attribute :active, :boolean do
      public? true
      allow_nil? false
      default true
    end

    attribute :last_synced_at, :utc_datetime do
      public? true
    end

    # Set on every sync attempt (success or failure); the heartbeat gates on this
    # so a persistently-failing feed is retried on its interval, not every minute.
    attribute :last_attempted_at, :utc_datetime do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    timestamps()
  end

  identities do
    identity :id, [:id]
  end
end
```

In `lib/family_dashboard/dashboard.ex`, add `define :upsert_calendar, action: :upsert` inside the `resource FamilyDashboard.Calendar do ... end` block:

```elixir
    resource FamilyDashboard.Calendar do
      define :list_calendars, action: :read
      define :get_calendar, action: :read, get_by: [:id]
      define :create_calendar, action: :create
      define :update_calendar, action: :update
      define :destroy_calendar, action: :destroy
      define :upsert_calendar, action: :upsert
    end
```

- [ ] **Step 4: Generate and run the migration**

Run: `mix ash.codegen calendar_upsert_identity`
Expected: since `:id` is already the primary key (and therefore already unique), the generated migration should be a no-op or near-no-op. Read it before applying — if it tries to add a redundant unique index on `id`, that's harmless; if it tries anything else, stop and investigate before proceeding.

Run: `mix ash.migrate`
Expected: applies without error.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/family_dashboard/calendar_test.exs`
Expected: PASS

Run the full suite: `mix test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/family_dashboard/calendar.ex lib/family_dashboard/dashboard.ex priv/repo/migrations priv/resource_snapshots test/family_dashboard/calendar_test.exs
git commit -m "Add a Calendar upsert-by-id action for restoring from a backup"
```

---

### Task 10: Backup module — export/import

**Files:**
- Create: `lib/family_dashboard/backup.ex`
- Test: `test/family_dashboard/backup_test.exs` (new)

**Interfaces:**
- Consumes: `Dashboard.list_calendars!/0`, `Dashboard.upsert_calendar!/1`, `Dashboard.update_calendar!/2`, `Dashboard.current_setting/0,!/0`, `Dashboard.create_setting!/1`, `Dashboard.update_setting!/2`, `Dashboard.record_weather_status!/2` (Task 9 + pre-existing).
- Produces: `Backup.export/0 :: map()`, `Backup.export_json/0 :: String.t()`, `Backup.write_to_disk/2 :: {:ok, path} | {:error, reason}`, `Backup.import_json/2 :: {:ok, %{calendars_restored: n}} | {:error, reason}`, `Backup.backup_dir/0 :: String.t()`. Used by `OpsLive` (Task 13), the download controller (Task 12), and the backup worker (Task 11).

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/backup_test.exs`:

```elixir
defmodule FamilyDashboard.BackupTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Backup, Dashboard}

  @tmp_dir Path.join(System.tmp_dir!(), "family_dashboard_backup_test")

  setup do
    File.rm_rf!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "export/0 and export_json/0" do
    test "includes version, calendars, and the singleton setting" do
      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      data = Backup.export()

      assert data["version"] == 1
      assert data["exported_at"]
      assert [%{"name" => "Family", "ical_url" => "https://x/cal.ics"}] = data["calendars"]
      assert data["setting"]["time_zone"]
    end

    test "export_json/0 produces valid, round-trippable JSON" do
      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      assert {:ok, decoded} = Backup.export_json() |> Jason.decode()
      assert decoded["version"] == 1
    end
  end

  describe "write_to_disk/2" do
    test "creates the directory and writes a timestamped file" do
      assert {:ok, path} = Backup.write_to_disk(~s({"ok":true}), @tmp_dir)

      assert File.exists?(path)
      assert Path.dirname(path) == @tmp_dir
      assert File.read!(path) == ~s({"ok":true})
    end
  end

  describe "import_json/2" do
    test "upserts an existing calendar by id without touching its id" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://old/cal.ics"})

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Family (renamed)",
            "ical_url" => "https://new/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, %{calendars_restored: 1}} =
               Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_calendar!(cal.id)
      assert reloaded.id == cal.id
      assert reloaded.name == "Family (renamed)"
      assert reloaded.ical_url == "https://new/cal.ics"
    end

    test "inserts a calendar not yet in the database" do
      new_id = Ash.UUID.generate()

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => new_id,
            "name" => "New",
            "ical_url" => "https://new/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)
      assert Dashboard.get_calendar!(new_id).name == "New"
    end

    test "resets a restored calendar's sync status" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

      Dashboard.update_calendar!(cal, %{
        last_error: "boom",
        last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Family",
            "ical_url" => "https://x/cal.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.get_calendar!(cal.id)
      assert is_nil(reloaded.last_error)
      assert is_nil(reloaded.last_synced_at)
    end

    test "leaves a calendar not present in the backup untouched" do
      untouched = Dashboard.create_calendar!(%{name: "Untouched", ical_url: "https://x/u.ics"})

      backup = Backup.export() |> put_in(["calendars"], []) |> Jason.encode!()

      assert {:ok, %{calendars_restored: 0}} =
               Backup.import_json(backup, skip_safety_export: true)

      assert Dashboard.get_calendar!(untouched.id).name == "Untouched"
    end

    test "updates the singleton setting and resets its status fields" do
      {:ok, setting} = Dashboard.current_setting()

      Dashboard.record_weather_status!(setting, %{
        weather_last_error: "boom",
        weather_last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      backup =
        Backup.export()
        |> put_in(["setting"], %{
          "latitude" => 10.0,
          "longitude" => 20.0,
          "city_label" => "Testville",
          "units" => "metric",
          "greeting" => "Hi",
          "time_zone" => "America/Chicago",
          "calendar_sync_minutes" => 15,
          "weather_refresh_minutes" => 15,
          "daily_refresh_minutes" => 60,
          "sync_max_attempts" => 3
        })
        |> Jason.encode!()

      assert {:ok, _} = Backup.import_json(backup, skip_safety_export: true)

      reloaded = Dashboard.current_setting!()
      assert reloaded.city_label == "Testville"
      assert is_nil(reloaded.weather_last_error)
      assert is_nil(reloaded.weather_last_attempted_at)
    end

    test "rejects an unsupported version" do
      bad = Backup.export() |> Map.put("version", 99) |> Jason.encode!()

      assert {:error, {:invalid_backup, _}} = Backup.import_json(bad, skip_safety_export: true)
    end

    test "rejects malformed JSON" do
      assert {:error, %Jason.DecodeError{}} =
               Backup.import_json("not json", skip_safety_export: true)
    end

    test "auto-exports the current state to disk before restoring, by default" do
      original_dir = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)
      on_exit(fn -> Application.put_env(:family_dashboard, :backup_dir, original_dir) end)

      Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      backup = Backup.export_json()

      assert {:ok, _} = Backup.import_json(backup)
      assert File.ls!(@tmp_dir) != []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard/backup_test.exs`
Expected: FAIL — `FamilyDashboard.Backup` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `lib/family_dashboard/backup.ex`:

```elixir
defmodule FamilyDashboard.Backup do
  @moduledoc """
  Exports/imports the hand-entered `calendars` + `settings` config as JSON —
  the only two tables in the domain that aren't regenerated by a sync (see
  `FamilyDashboard.Sync`). Weather readings and events are deliberately
  excluded; they refresh themselves on the next scheduled sync.

  Restore semantics:

    * calendars are upserted **by id** — an existing calendar is updated in
      place, a calendar not yet in the DB is inserted, and any calendar not
      present in the backup is left alone. This preserves `events.calendar_id`
      (a restore can never orphan an event).
    * the singleton setting is updated in place (or created if unseeded).
    * system-set sync-status fields (`last_synced_at`, `last_attempted_at`,
      `last_error` on each restored calendar; `weather_last_error`,
      `weather_last_attempted_at`, `daily_last_attempted_at` on the setting)
      are reset to `nil` rather than restored from a stale snapshot — the next
      heartbeat tick re-establishes real status within one cycle.
  """

  require Logger

  alias FamilyDashboard.Dashboard

  @version 1

  @doc "Builds the exportable structure: version, timestamp, calendars, setting."
  @spec export() :: map()
  def export do
    %{
      "version" => @version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "calendars" => Enum.map(Dashboard.list_calendars!(), &calendar_json/1),
      "setting" => setting_json(current_setting())
    }
  end

  @doc "`export/0` encoded as a pretty JSON string."
  @spec export_json() :: String.t()
  def export_json, do: export() |> Jason.encode!(pretty: true)

  @doc """
  Writes `json` to `<dir>/family_dashboard_backup_<timestamp>.json`, creating
  `dir` if needed. Returns `{:ok, path}` or `{:error, reason}` (a `File` error).
  """
  @spec write_to_disk(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_to_disk(json, dir \\ backup_dir()) do
    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "family_dashboard_backup_#{timestamp()}.json")

      case File.write(path, json) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The configured backup directory (see `config/runtime.exs`)."
  @spec backup_dir() :: String.t()
  def backup_dir do
    Application.get_env(:family_dashboard, :backup_dir) ||
      Path.expand("../../priv/backups", __DIR__)
  end

  @doc """
  Restores calendars (upsert by id) and the setting (update-or-create) from a
  backup JSON string. Auto-exports the *current* state to disk first, as a
  safety net, before making any change — pass `skip_safety_export: true` to
  suppress this (used in tests). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec import_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_json(json, opts \\ []) do
    with {:ok, decoded} <- Jason.decode(json),
         {:ok, data} <- validate(decoded) do
      unless opts[:skip_safety_export] do
        case write_to_disk(export_json()) do
          {:ok, _path} ->
            :ok

          {:error, reason} ->
            Logger.warning("Backup safety-export before restore failed: #{inspect(reason)}")
        end
      end

      calendars = Enum.map(data["calendars"], &Dashboard.upsert_calendar!/1)
      reset_calendar_status(calendars)
      restore_setting(data["setting"])

      {:ok, %{calendars_restored: length(calendars)}}
    end
  end

  defp validate(%{"version" => @version, "calendars" => calendars, "setting" => setting} = data)
       when is_list(calendars) and is_map(setting) do
    {:ok, data}
  end

  defp validate(%{"version" => version}) when version != @version do
    {:error, {:invalid_backup, "unsupported version #{inspect(version)}"}}
  end

  defp validate(_data), do: {:error, {:invalid_backup, "missing calendars or setting"}}

  defp reset_calendar_status(calendars) do
    Enum.each(calendars, fn cal ->
      Dashboard.update_calendar!(cal, %{
        last_synced_at: nil,
        last_attempted_at: nil,
        last_error: nil
      })
    end)
  end

  defp restore_setting(attrs) do
    setting_attrs = Map.take(attrs, writable_setting_fields())

    setting =
      case current_setting() do
        nil -> Dashboard.create_setting!(setting_attrs)
        existing -> Dashboard.update_setting!(existing, setting_attrs)
      end

    Dashboard.record_weather_status!(setting, %{
      weather_last_error: nil,
      weather_last_attempted_at: nil,
      daily_last_attempted_at: nil
    })
  end

  defp writable_setting_fields do
    ~w(latitude longitude city_label units greeting time_zone calendar_sync_minutes weather_refresh_minutes daily_refresh_minutes sync_max_attempts)
  end

  defp calendar_json(cal) do
    %{
      "id" => cal.id,
      "name" => cal.name,
      "ical_url" => cal.ical_url,
      "color" => cal.color,
      "active" => cal.active,
      "last_synced_at" => datetime_json(cal.last_synced_at),
      "last_attempted_at" => datetime_json(cal.last_attempted_at),
      "last_error" => cal.last_error
    }
  end

  defp setting_json(nil), do: %{}

  defp setting_json(setting) do
    %{
      "latitude" => setting.latitude,
      "longitude" => setting.longitude,
      "city_label" => setting.city_label,
      "units" => setting.units,
      "greeting" => setting.greeting,
      "time_zone" => setting.time_zone,
      "calendar_sync_minutes" => setting.calendar_sync_minutes,
      "weather_refresh_minutes" => setting.weather_refresh_minutes,
      "daily_refresh_minutes" => setting.daily_refresh_minutes,
      "sync_max_attempts" => setting.sync_max_attempts,
      # Exported for human readability only; ignored on import (see @moduledoc).
      "weather_last_error" => setting.weather_last_error,
      "weather_last_attempted_at" => datetime_json(setting.weather_last_attempted_at),
      "daily_last_attempted_at" => datetime_json(setting.daily_last_attempted_at)
    }
  end

  defp datetime_json(nil), do: nil
  defp datetime_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/backup_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/backup.ex test/family_dashboard/backup_test.exs
git commit -m "Add FamilyDashboard.Backup for calendars/settings JSON export and restore"
```

---

### Task 11: Scheduled auto-backup worker

**Files:**
- Create: `lib/family_dashboard/workers/backup.ex`
- Modify: `config/config.exs`
- Test: `test/family_dashboard/workers/backup_test.exs` (new)

**Interfaces:**
- Consumes: `Backup.export_json/0`, `Backup.write_to_disk/1` (Task 10).

- [ ] **Step 1: Write the failing test**

Create `test/family_dashboard/workers/backup_test.exs`:

```elixir
defmodule FamilyDashboard.Workers.BackupTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.Backup, as: BackupWorker

  @tmp_dir Path.join(System.tmp_dir!(), "family_dashboard_backup_worker_test")

  setup do
    File.rm_rf!(@tmp_dir)
    original = Application.get_env(:family_dashboard, :backup_dir)
    Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.put_env(:family_dashboard, :backup_dir, original)
    end)

    :ok
  end

  test "writes a backup file to the configured directory" do
    assert :ok = perform_job(BackupWorker, %{})
    assert File.ls!(@tmp_dir) != []
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/family_dashboard/workers/backup_test.exs`
Expected: FAIL — `FamilyDashboard.Workers.Backup` doesn't exist.

- [ ] **Step 3: Write the implementation**

Create `lib/family_dashboard/workers/backup.ex`:

```elixir
defmodule FamilyDashboard.Workers.Backup do
  @moduledoc """
  Writes a dated JSON backup of `calendars` + `settings` to disk on a daily
  cron schedule (see `config/config.exs`). Independent of the heartbeat's
  due-gating — a backup must run on a fixed cadence even before the `Setting`
  singleton is seeded.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.Backup

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Backup.export_json() |> Backup.write_to_disk() do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

In `config/config.exs`, change the Oban `plugins:` line from:

```elixir
  plugins: [{Oban.Plugins.Cron, []}]
```

to:

```elixir
  plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", FamilyDashboard.Workers.Backup}]}]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/family_dashboard/workers/backup_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/workers/backup.ex config/config.exs test/family_dashboard/workers/backup_test.exs
git commit -m "Add a daily cron job that backs up calendars/settings to disk"
```

---

### Task 12: Backup download controller

**Files:**
- Create: `lib/family_dashboard_web/controllers/backup_controller.ex`
- Modify: `lib/family_dashboard_web/router.ex`
- Test: `test/family_dashboard_web/controllers/backup_controller_test.exs` (new)

**Interfaces:**
- Consumes: `Backup.export_json/0` (Task 10).
- Produces: `GET /ops/backup.json` → a downloadable JSON attachment, gated by `:settings_area`.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard_web/controllers/backup_controller_test.exs`:

```elixir
defmodule FamilyDashboardWeb.BackupControllerTest do
  use FamilyDashboardWeb.ConnCase

  alias FamilyDashboard.Dashboard

  @auth Plug.BasicAuth.encode_basic_auth("family", "family-dashboard")

  test "requires the settings password", %{conn: conn} do
    conn = get(conn, "/ops/backup.json")
    assert conn.status == 401
  end

  test "returns the current backup as a JSON download", %{conn: conn} do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})

    conn =
      conn
      |> put_req_header("authorization", @auth)
      |> get("/ops/backup.json")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"

    assert {:ok, decoded} = Jason.decode(conn.resp_body)
    assert decoded["version"] == 1
    assert [%{"name" => "Family"}] = decoded["calendars"]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/controllers/backup_controller_test.exs`
Expected: FAIL — no route/controller exists yet.

- [ ] **Step 3: Add the controller and route**

Create `lib/family_dashboard_web/controllers/backup_controller.ex`:

```elixir
defmodule FamilyDashboardWeb.BackupController do
  @moduledoc """
  Serves the current calendars/settings backup as a JSON file download — kept
  out of the ops LiveView's socket so a large export doesn't round-trip
  through the websocket connection.
  """
  use FamilyDashboardWeb, :controller

  alias FamilyDashboard.Backup

  def download(conn, _params) do
    filename = "family_dashboard_backup_#{Date.utc_today()}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, Backup.export_json())
  end
end
```

In `lib/family_dashboard_web/router.ex`, add one more line to the `:settings_area` scope from Task 7:

```elixir
  scope "/" do
    pipe_through [:browser, :settings_area]

    ash_admin "/admin"
    oban_dashboard("/oban")
    live "/ops", FamilyDashboardWeb.OpsLive, :index
    get "/ops/backup.json", FamilyDashboardWeb.BackupController, :download
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/controllers/backup_controller_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard_web/controllers/backup_controller.ex lib/family_dashboard_web/router.ex test/family_dashboard_web/controllers/backup_controller_test.exs
git commit -m "Add a /ops/backup.json download endpoint"
```

---

### Task 13: OpsLive — export/restore UI

**Files:**
- Modify: `lib/family_dashboard_web/live/ops_live.ex`
- Modify: `test/family_dashboard_web/live/ops_live_test.exs`

**Interfaces:**
- Consumes: `Backup.export_json/0`, `Backup.write_to_disk/0`, `Backup.import_json/1` (Task 10).

- [ ] **Step 1: Write the failing tests**

In `test/family_dashboard_web/live/ops_live_test.exs`, add `alias FamilyDashboard.Backup` and append a new describe block:

```elixir
  describe "backup & restore" do
    test "save_backup_to_disk writes a file and flashes success", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "ops_live_backup_test")
      File.rm_rf!(tmp)
      original = Application.get_env(:family_dashboard, :backup_dir)
      Application.put_env(:family_dashboard, :backup_dir, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.put_env(:family_dashboard, :backup_dir, original)
      end)

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "save_backup_to_disk")

      assert html =~ "Backup saved"
      assert File.ls!(tmp) != []
    end

    test "request_restore then cancel_restore hides the confirm step", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      html = render_click(live, "request_restore")
      assert html =~ "Yes, overwrite"

      html = render_click(live, "cancel_restore")
      refute html =~ "Yes, overwrite"
    end

    test "confirming restore without a selected file shows an error", %{conn: conn} do
      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      render_click(live, "request_restore")
      html = render_click(live, "confirm_restore")

      assert html =~ "Choose a backup file first."
    end

    test "restoring an uploaded backup upserts calendars and flashes a summary", %{conn: conn} do
      cal = Dashboard.create_calendar!(%{name: "Old", ical_url: "https://x/old.ics"})

      backup =
        Backup.export()
        |> put_in(["calendars"], [
          %{
            "id" => cal.id,
            "name" => "Restored",
            "ical_url" => "https://x/old.ics",
            "color" => nil,
            "active" => true
          }
        ])
        |> Jason.encode!()

      {:ok, live, _html} = conn |> authed() |> live(~p"/ops")

      file =
        file_input(live, "#restore-form", :backup, [
          %{name: "backup.json", content: backup, type: "application/json"}
        ])

      render_upload(file, "backup.json")
      render_click(live, "request_restore")
      html = live |> element("#restore-form") |> render_submit()

      assert html =~ "Restored 1 calendar(s)"
      assert Dashboard.get_calendar!(cal.id).name == "Restored"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: FAIL — the backup/restore UI and events don't exist yet.

- [ ] **Step 3: Add the upload setup and UI**

In `lib/family_dashboard_web/live/ops_live.ex`, add `alias FamilyDashboard.Backup` next to the existing aliases. Update `mount/3`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
        reload_status(socket)
      else
        assign(socket, calendars: [], setting: nil)
      end

    socket =
      socket
      |> assign(confirming_restore: false, restore_error: nil)
      |> allow_upload(:backup, accept: ~w(.json), max_entries: 1)

    {:ok, socket}
  end
```

Add a new `<section>` at the end of the `<div class="max-w-3xl ...">` in `render/1`, right before the closing `</div>` (after the Calendars section):

```heex
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Backup &amp; restore</h2>
            <p class="text-sm text-base-content/70">
              Backs up calendars and settings only — weather and events regenerate on the next sync.
            </p>
            <div class="flex gap-2">
              <.button href={~p"/ops/backup.json"} download>Download backup</.button>
              <.button phx-click="save_backup_to_disk">Save to disk now</.button>
            </div>

            <form
              id="restore-form"
              phx-submit="confirm_restore"
              phx-change="validate_upload"
              class="mt-4 flex flex-col gap-2"
            >
              <.live_file_input upload={@uploads.backup} />
              <p :for={err <- upload_errors(@uploads.backup)} class="text-error text-sm">
                {error_to_string(err)}
              </p>

              <div :if={!@confirming_restore}>
                <.button type="button" phx-click="request_restore">Restore from file…</.button>
              </div>

              <div :if={@confirming_restore} class="alert alert-warning">
                <span>This overwrites current calendars and settings. A safety backup is saved first.</span>
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">Yes, overwrite</.button>
                  <.button type="button" phx-click="cancel_restore">Cancel</.button>
                </div>
              </div>

              <p :if={@restore_error} class="text-error text-sm">{@restore_error}</p>
            </form>
          </div>
        </section>
```

- [ ] **Step 4: Add the event handlers**

Add these `handle_event/3` clauses next to the Task 8 ones, and the `error_to_string/1` helper at the bottom of the module:

```elixir
  def handle_event("save_backup_to_disk", _params, socket) do
    case Backup.export_json() |> Backup.write_to_disk() do
      {:ok, path} -> {:noreply, put_flash(socket, :info, "Backup saved to #{path}.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Backup failed: #{inspect(reason)}")}
    end
  end

  def handle_event("request_restore", _params, socket) do
    {:noreply, assign(socket, confirming_restore: true)}
  end

  def handle_event("cancel_restore", _params, socket) do
    {:noreply, assign(socket, confirming_restore: false, restore_error: nil)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_restore", _params, socket) do
    entries =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case entries do
      [json] ->
        case Backup.import_json(json) do
          {:ok, %{calendars_restored: n}} ->
            socket =
              socket
              |> put_flash(:info, "Restored #{n} calendar(s) and the settings.")
              |> assign(confirming_restore: false, restore_error: nil)
              |> reload_status()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, assign(socket, restore_error: inspect(reason))}
        end

      [] ->
        {:noreply, assign(socket, restore_error: "Choose a backup file first.")}
    end
  end

  defp error_to_string(:too_large), do: "File too large."
  defp error_to_string(:not_accepted), do: "Must be a .json file."
  defp error_to_string(:too_many_files), do: "Only one file at a time."
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/family_dashboard_web/live/ops_live_test.exs`
Expected: PASS

Run the full suite: `mix test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/family_dashboard_web/live/ops_live.ex test/family_dashboard_web/live/ops_live_test.exs
git commit -m "Add backup export/restore UI to the ops hub"
```

---

## Final verification

After Task 13:

1. `mix compile --warnings-as-errors` — no warnings.
2. `mix format` — no diffs (or apply and re-check).
3. `mix test` — full suite green.
4. Manual check: `mix phx.server`, then:
   - Visit `/ops` (prompted for the shared password) — confirm the status panel, trigger buttons, and backup/restore UI render.
   - Click each trigger button; watch `/oban` for the enqueued job and confirm the public dashboard `/` updates live once it completes.
   - Visit `/admin`; confirm `WeatherHourly` and `WeatherDaily` resources are listed and populated after a weather refresh.
   - Click "Download backup" — confirm a `.json` file downloads with `calendars` + `setting` keys.
   - Edit a calendar's name in `/admin`, then restore the downloaded backup from `/ops` — confirm the name reverts and no events were deleted.
