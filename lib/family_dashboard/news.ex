defmodule FamilyDashboard.News do
  @moduledoc """
  Fetches and normalizes RSS/Atom feeds into plain item maps — the same
  "normalize to plain maps" seam `FamilyDashboard.Weather.Provider` adapters
  use, so persistence stays parser-agnostic. XML parsing is wrapped behind
  this module (via the `fiet` dependency) rather than called directly from
  anywhere else, so swapping the underlying library later never touches a
  caller.
  """

  alias FamilyDashboard.Dashboard

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @rfc822 ~r/(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*(GMT|UT|Z|[+-]\d{4})?/

  @doc """
  Fetches and parses one feed URL. Returns `{:ok, [item]}` where each item is
  `%{title:, url:, guid:, published_at:}`, or `{:error, reason}` on an HTTP or
  parse failure. Items missing a title or url are dropped — a headline with
  nowhere to link is useless on the ticker. `opts` is passed through to
  `Req.get/1` (e.g. `plug:` in tests, mirroring `Weather.Xweather`'s `get/3`).
  """
  @spec fetch_items(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_items(url, opts \\ []) do
    request = Keyword.merge([url: url, retry: false, receive_timeout: 10_000], opts)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(body) when is_binary(body) do
    case Fiet.parse(body) do
      {:ok, %Fiet.Feed{items: items}} ->
        {:ok, items |> Enum.map(&normalize_item/1) |> Enum.filter(& &1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_item(%Fiet.Item{title: title, link: url}) when is_nil(title) or is_nil(url) do
    nil
  end

  defp normalize_item(%Fiet.Item{} = item) do
    %{
      title: item.title,
      url: item.link,
      guid: item.id || item.link,
      published_at: parse_timestamp(item.published_at)
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      {:error, _} -> parse_rfc822(raw)
    end
  end

  defp parse_rfc822(raw) do
    case Regex.run(@rfc822, raw) do
      [_, day, mon, year, hour, min, sec, zone] ->
        with month when not is_nil(month) <- @months[mon],
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec)
               ) do
          naive |> apply_zone_offset(zone) |> DateTime.truncate(:second)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp apply_zone_offset(naive, zone) when zone in [nil, "", "GMT", "UT", "Z"] do
    DateTime.new!(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), "Etc/UTC")
  end

  defp apply_zone_offset(naive, <<sign, h1, h2, m1, m2>>) when sign in [?+, ?-] do
    offset = String.to_integer(<<h1, h2>>) * 3600 + String.to_integer(<<m1, m2>>) * 60
    offset = if sign == ?-, do: -offset, else: offset

    shifted = NaiveDateTime.add(naive, -offset, :second)
    DateTime.new!(NaiveDateTime.to_date(shifted), NaiveDateTime.to_time(shifted), "Etc/UTC")
  end

  @doc """
  Fetches every enabled feed, each independently and best-effort, and upserts
  its items. A feed that fails to fetch keeps its existing items and records
  `last_error` — unlike `Sync.sync_calendar/2`, this never prunes; old items
  are removed only by `FamilyDashboard.NewsReaper`, on its own schedule.
  Always stamps `Setting.news_last_attempted_at`, regardless of per-feed
  outcome, so `Heartbeat` doesn't re-enqueue every minute.

  Items whose `published_at` is older than `news_retention_hours` are dropped
  before persisting — some feeds (observed on CNN) occasionally serve items
  with stale pubDates years in the past, and `NewsReaper` only guarantees
  reaping items *older* than the window while always protecting the newest
  item per feed, so a stale item let in here could otherwise linger on the
  ticker indefinitely. Items with no `published_at` are always kept (they
  fall back to fetch time, which is always fresh).
  """
  @spec refresh_all(keyword()) :: :ok
  def refresh_all(opts \\ []) do
    record_attempt()
    cutoff = retention_cutoff()

    Dashboard.list_news_feeds!()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(&refresh_feed(&1, cutoff, opts))

    broadcast("news", :news_updated)
    :ok
  end

  defp refresh_feed(feed, cutoff, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case fetch_items(feed.url, opts) do
      {:ok, items} ->
        items
        |> Enum.filter(&fresh?(&1, cutoff))
        |> Enum.each(fn item ->
          Dashboard.create_news_item!(Map.put(item, :news_feed_id, feed.id))
        end)

        Dashboard.update_news_feed!(feed, %{last_fetched_at: now, last_error: nil})

      {:error, reason} ->
        Dashboard.update_news_feed!(feed, %{last_error: inspect(reason)})
    end
  end

  defp fresh?(%{published_at: nil}, _cutoff), do: true

  defp fresh?(%{published_at: published_at}, cutoff),
    do: DateTime.compare(published_at, cutoff) != :lt

  defp retention_cutoff do
    hours =
      case Dashboard.current_setting() do
        {:ok, %{news_retention_hours: hours}} when is_integer(hours) -> hours
        _ -> 24
      end

    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-hours * 3600, :second)
  end

  defp record_attempt do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Dashboard.current_setting() do
      {:ok, %{} = setting} ->
        Dashboard.record_news_attempt!(setting, %{news_last_attempted_at: now})

      _ ->
        :ok
    end
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(FamilyDashboard.PubSub, topic, message)
  end
end
