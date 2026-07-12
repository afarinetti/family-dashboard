defmodule FamilyDashboard.NewsReaperTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, NewsReaper}

  defp create_feed(label \\ "Example") do
    Dashboard.create_news_feed!(%{url: "https://example.com/#{label}.xml", label: label})
  end

  defp create_item(feed, guid, published_at) do
    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: guid,
      title: "Item #{guid}",
      url: "https://example.com/#{guid}",
      published_at: published_at
    })
  end

  defp item_ids do
    FamilyDashboard.NewsItem |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes items older than the retention window" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old = create_item(feed, "old", DateTime.add(now, -48, :hour))
    recent = create_item(feed, "recent", DateTime.add(now, -1, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [recent.id]
    refute old.id in item_ids()
  end

  test "always protects the newest item per feed, even if it's older than the window" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    only_item = create_item(feed, "only", DateTime.add(now, -72, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [only_item.id]
  end

  test "protects the newest item independently per feed" do
    feed_a = create_feed("A")
    feed_b = create_feed("B")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    a_only = create_item(feed_a, "a-only", DateTime.add(now, -72, :hour))
    b_only = create_item(feed_b, "b-only", DateTime.add(now, -72, :hour))

    assert :ok = NewsReaper.reap()

    assert Enum.sort(item_ids()) == Enum.sort([a_only.id, b_only.id])
  end

  test "falls back to inserted_at for an item with no published_at" do
    feed = create_feed()

    recent_no_date =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "no-date",
        title: "No date",
        url: "https://example.com/no-date"
      })

    old_dated =
      create_item(
        feed,
        "old-dated",
        DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second)
      )

    assert :ok = NewsReaper.reap()

    assert item_ids() == [recent_no_date.id]
    refute old_dated.id in item_ids()
  end

  test "does nothing when there are no items" do
    assert :ok = NewsReaper.reap()
    assert item_ids() == []
  end

  test "respects a custom news_retention_hours setting" do
    feed = create_feed()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, setting} = Dashboard.current_setting()
    Dashboard.update_setting!(setting, %{news_retention_hours: 1})

    within_new_window = create_item(feed, "within", DateTime.add(now, -30, :minute))
    outside_new_window = create_item(feed, "outside", DateTime.add(now, -2, :hour))

    assert :ok = NewsReaper.reap()

    assert item_ids() == [within_new_window.id]
    refute outside_new_window.id in item_ids()
  end
end
