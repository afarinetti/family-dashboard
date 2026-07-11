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
            Dashboard.record_weather!(carry_forward_daily(attrs))
            record_weather_status(setting, nil)
            broadcast("weather", :weather_updated)
            :ok

          {:error, reason} ->
            record_weather_status(setting, humanize_weather_error(reason))
            {:error, reason}
        end
    end
  end

  @doc """
  Refreshes just the 7-day forecast — its own (less frequent, higher-retry) Oban
  job because the daily endpoint is slow and flaky. Patches the latest reading's
  `days` and today's high/low in place. Returns `:ok` or `{:error, reason}`.
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
  # current+hourly refresh); patch its days + today's high/low in place.
  defp apply_daily_to_latest(days) do
    case Dashboard.latest_weather() do
      {:ok, %{} = reading} ->
        today = List.first(days) || %{}
        forecast = Map.put(reading.forecast || %{}, "days", days)

        Dashboard.update_weather_reading!(reading, %{
          forecast: forecast,
          high: today["high"],
          low: today["low"]
        })

        broadcast("weather", :weather_updated)
        :ok

      # No reading yet; the next current+hourly refresh creates one and the
      # following daily cycle fills it in.
      _ ->
        {:error, :no_reading}
    end
  end

  defp record_daily_attempt(setting) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Dashboard.record_weather_status!(setting, %{daily_last_attempted_at: now})
  end

  # The fast current+hourly refresh carries the last known 7-day (days + today's
  # high/low) forward so the widget stays populated between daily-job runs.
  defp carry_forward_daily(attrs) do
    case Dashboard.latest_weather() do
      {:ok, %{} = prev} ->
        attrs
        |> put_in([:forecast, "days"], prev.forecast["days"] || [])
        |> Map.put(:high, prev.high)
        |> Map.put(:low, prev.low)

      _ ->
        attrs
    end
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
