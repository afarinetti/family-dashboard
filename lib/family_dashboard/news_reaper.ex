defmodule FamilyDashboard.NewsReaper do
  @moduledoc """
  Deletes old `NewsItem` rows on a daily cron schedule (see
  `config/config.exs`), keyed off each item's `effective_time/1`
  (`published_at`, falling back to `inserted_at`). The newest item **per
  feed** is always protected, even if it's older than the retention window —
  mirrors `WeatherReaper`'s protect-latest rule, so a feed that goes quiet
  doesn't blank the ticker entirely.
  """

  alias FamilyDashboard.{Dashboard, NewsItem}

  @default_retention_hours 24

  @doc "Deletes news items older than the configured retention window, protecting the newest per feed."
  @spec reap() :: :ok
  def reap do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_hours(), :hour)
    items = NewsItem |> Ash.read!()
    protected_ids = protected_ids(items)

    stale =
      items
      |> Enum.reject(&(&1.id in protected_ids))
      |> Enum.filter(&(DateTime.compare(NewsItem.effective_time(&1), cutoff) == :lt))

    unless stale == [] do
      Ash.bulk_destroy!(stale, :destroy, %{}, strategy: [:stream])
    end

    :ok
  end

  defp protected_ids(items) do
    items
    |> Enum.group_by(& &1.news_feed_id)
    |> Enum.map(fn {_feed_id, feed_items} ->
      feed_items |> Enum.max_by(&NewsItem.effective_time/1, DateTime) |> Map.fetch!(:id)
    end)
  end

  defp retention_hours do
    case Dashboard.current_setting() do
      {:ok, %{news_retention_hours: hours}} when is_integer(hours) -> hours
      _ -> @default_retention_hours
    end
  end
end
