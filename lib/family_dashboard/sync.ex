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
    if is_nil(Application.get_env(:family_dashboard, :openweather_api_key)) and opts == [] do
      {:error, :no_api_key}
    else
      do_refresh_weather(opts)
    end
  end

  defp do_refresh_weather(opts) do
    case Dashboard.current_setting() do
      {:ok, %{latitude: lat, longitude: lon} = setting}
      when not is_nil(lat) and not is_nil(lon) ->
        case Weather.fetch(lat, lon, setting.units || "metric", opts) do
          {:ok, attrs} ->
            Dashboard.record_weather!(attrs)
            broadcast("weather", :weather_updated)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_location}
    end
  end

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

        Dashboard.update_calendar!(calendar, %{last_synced_at: now, last_error: nil})
      end)

    :ok
  end

  defp record_error(calendar, reason) do
    Dashboard.update_calendar!(calendar, %{last_error: inspect(reason)})
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(FamilyDashboard.PubSub, topic, message)
  end
end
