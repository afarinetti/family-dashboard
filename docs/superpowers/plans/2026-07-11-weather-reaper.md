# Weather Reaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daily Oban job that deletes `WeatherReading` rows (and their `WeatherHourly`/`WeatherDaily` children) older than 48 hours, always protecting the current latest reading.

**Architecture:** A pure `FamilyDashboard.WeatherReaper` module holding the deletion logic, plus a thin `FamilyDashboard.Workers.WeatherReap` Oban worker that delegates to it — mirroring the existing `Backup`/`Workers.Backup` split. Scheduled via the same daily `Oban.Plugins.Cron` config entry that already runs the backup job.

**Tech Stack:** Elixir ~1.17, Ash 3.29.3, ash_sqlite 0.2.17, Oban 2.23.0 (SQLite engine).

## Global Constraints

- Retention window is a hardcoded module attribute (`@retention_hours 48`), not a Settings-configurable knob — matches the existing convention of `@window_days 21` in `Sync` and `@hours`/`@days` in `Weather`.
- The current latest `WeatherReading` (per `Dashboard.latest_weather/0`) is always protected from reaping, regardless of age.
- Neither the `WeatherHourly` nor `WeatherDaily` foreign key has an `on_delete` cascade at the DB level (confirmed in `priv/repo/migrations/20260711143344_normalize_weather.exs`) — children must be explicitly bulk-destroyed before their parent `WeatherReading` rows, same two-phase pattern `Sync.replace_window_events` already uses for calendar-event pruning.
- Ash resolves `id in []` to "match nothing" — when the reap set is empty, skip the destroy calls entirely rather than relying on that resolving to a no-op the hard way.
- Commit messages are plain imperative sentences with no prefix (e.g. "Fix iCal RRULE UNTIL handling", not "feat: fix...").
- No UI surface for this feature — no `/ops` button, no LiveView/controller changes.

---

### Task 1: WeatherReaper module

**Files:**
- Create: `lib/family_dashboard/weather_reaper.ex`
- Test: `test/family_dashboard/weather_reaper_test.exs`

**Interfaces:**
- Consumes: `FamilyDashboard.Dashboard.latest_weather/0` (returns `{:ok, %WeatherReading{}} | {:ok, nil}`, pre-existing), `Dashboard.record_weather!/1`, `Dashboard.create_weather_hourly!/1`, `Dashboard.create_weather_daily!/1` (all pre-existing, used by tests to build fixtures).
- Produces: `FamilyDashboard.WeatherReaper.reap/0 :: :ok` — used by Task 2's worker.

- [ ] **Step 1: Write the failing tests**

Create `test/family_dashboard/weather_reaper_test.exs`:

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

  defp reading_ids do
    FamilyDashboard.WeatherReading |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes readings older than 48 hours, along with their hourly/daily children" do
    old =
      create_reading(DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second))

    add_hourly(old)
    add_daily(old)

    recent = create_reading(DateTime.utc_now() |> DateTime.truncate(:second))

    assert :ok = WeatherReaper.reap()

    assert reading_ids() == [recent.id]
    assert FamilyDashboard.WeatherHourly |> Ash.read!() == []
    assert FamilyDashboard.WeatherDaily |> Ash.read!() == []
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

Run: `mix test test/family_dashboard/weather_reaper_test.exs`
Expected: FAIL — `FamilyDashboard.WeatherReaper` doesn't exist.

- [ ] **Step 3: Write the implementation**

Create `lib/family_dashboard/weather_reaper.ex`:

```elixir
defmodule FamilyDashboard.WeatherReaper do
  @moduledoc """
  Deletes old `WeatherReading` rows (and their `WeatherHourly`/`WeatherDaily`
  children) on a daily cron schedule (see `config/config.exs`). Only the
  latest reading is ever read anywhere in the app — everything older is pure
  accumulated history with no read path.

  The current latest reading is always protected, even if it's older than the
  retention window: if refreshes break for an extended period, the dashboard
  should keep showing the last-known (stale) reading rather than reaping down
  to nothing.
  """

  require Ash.Query

  alias FamilyDashboard.{Dashboard, WeatherDaily, WeatherHourly, WeatherReading}

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/family_dashboard/weather_reaper_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/family_dashboard/weather_reaper.ex test/family_dashboard/weather_reaper_test.exs
git commit -m "Add WeatherReaper to delete weather readings older than 48 hours"
```

---

### Task 2: Scheduled worker + cron entry

**Files:**
- Create: `lib/family_dashboard/workers/weather_reap.ex`
- Modify: `config/config.exs`
- Test: `test/family_dashboard/workers/weather_reap_test.exs`

**Interfaces:**
- Consumes: `FamilyDashboard.WeatherReaper.reap/0` (Task 1).

- [ ] **Step 1: Write the failing test**

Create `test/family_dashboard/workers/weather_reap_test.exs`:

```elixir
defmodule FamilyDashboard.Workers.WeatherReapTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.WeatherReap

  test "delegates to WeatherReaper.reap/0" do
    assert :ok = perform_job(WeatherReap, %{})
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/family_dashboard/workers/weather_reap_test.exs`
Expected: FAIL — `FamilyDashboard.Workers.WeatherReap` doesn't exist.

- [ ] **Step 3: Write the worker**

Create `lib/family_dashboard/workers/weather_reap.ex`:

```elixir
defmodule FamilyDashboard.Workers.WeatherReap do
  @moduledoc """
  Reaps old weather readings on a daily cron schedule (see
  `config/config.exs`), alongside the backup job. See
  `FamilyDashboard.WeatherReaper` for the retention policy.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias FamilyDashboard.WeatherReaper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    WeatherReaper.reap()
  end
end
```

- [ ] **Step 4: Add the cron entry**

In `config/config.exs`, change the Oban `plugins:` line from:

```elixir
  plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", FamilyDashboard.Workers.Backup}]}]
```

to:

```elixir
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", FamilyDashboard.Workers.Backup},
       {"0 3 * * *", FamilyDashboard.Workers.WeatherReap}
     ]}
  ]
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/family_dashboard/workers/weather_reap_test.exs`
Expected: PASS

- [ ] **Step 6: Run the full suite once**

Run: `mix test`
Expected: PASS, full suite green.

- [ ] **Step 7: Commit**

```bash
git add lib/family_dashboard/workers/weather_reap.ex config/config.exs test/family_dashboard/workers/weather_reap_test.exs
git commit -m "Schedule the weather reaper on the daily cron alongside the backup job"
```

---

## Final Verification

1. `mix format --check-formatted` — clean.
2. `mix compile --warnings-as-errors` — clean.
3. `mix test` — full suite green.
4. Manual check (optional): `mix phx.server`, then in `iex -S mix`, `FamilyDashboard.WeatherReaper.reap()` and confirm it returns `:ok` with no errors against the real dev DB.
