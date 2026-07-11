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
            Dashboard.record_weather!(carry_forward_days(attrs))
            record_weather_status(setting, nil)
            broadcast("weather", :weather_updated)
            :ok

          {:error, reason} ->
            record_weather_status(setting, humanize_weather_error(reason))
            {:error, reason}
        end
    end
  end

  # OWM's daily endpoint intermittently returns empty; when this refresh has no
  # 7-day data, keep the last known forecast so the widget doesn't flicker.
  defp carry_forward_days(attrs) do
    if get_in(attrs, [:forecast, "days"]) in [nil, []] do
      case Dashboard.latest_weather() do
        {:ok, %{forecast: %{"days" => prev}}} when prev not in [nil, []] ->
          put_in(attrs, [:forecast, "days"], prev)

        _ ->
          attrs
      end
    else
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

  # Delete + reinsert the calendar's occurrences in the window, atomically. Using
  # bang calls means any failure raises and rolls the whole transaction back.
  defp replace_window_events(calendar, occurrences, from, to) do
    from_dt = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(to, ~T[23:59:59], "Etc/UTC")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      FamilyDashboard.Repo.transaction(fn ->
        FamilyDashboard.Event
        |> Ash.Query.filter(
          calendar_id == ^calendar.id and starts_at >= ^from_dt and starts_at <= ^to_dt
        )
        |> Ash.bulk_destroy!(:destroy, %{}, strategy: [:stream])

        Enum.each(occurrences, fn occ ->
          Dashboard.create_event!(%{
            calendar_id: calendar.id,
            uid: occ.uid,
            title: occ.title,
            starts_at: occ.starts_at,
            ends_at: occ.ends_at,
            all_day: occ.all_day?,
            location: occ.location
          })
        end)

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
