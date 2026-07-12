defmodule FamilyDashboard.NewsItemTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp create_feed do
    Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})
  end

  test "creates an item attached to a feed" do
    feed = create_feed()

    assert {:ok, item} =
             Dashboard.create_news_item(%{
               news_feed_id: feed.id,
               guid: "item-1",
               title: "Headline",
               url: "https://example.com/a",
               published_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert item.news_feed_id == feed.id
    assert item.title == "Headline"
  end

  test "requires title, url, and guid" do
    feed = create_feed()
    assert {:error, _} = Dashboard.create_news_item(%{news_feed_id: feed.id})
  end

  test "upserts on [news_feed_id, guid] instead of creating a duplicate" do
    feed = create_feed()

    first =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "item-1",
        title: "Original headline",
        url: "https://example.com/a"
      })

    second =
      Dashboard.create_news_item!(%{
        news_feed_id: feed.id,
        guid: "item-1",
        title: "Updated headline",
        url: "https://example.com/a-updated"
      })

    assert second.id == first.id
    assert second.title == "Updated headline"
    assert FamilyDashboard.NewsItem |> Ash.read!() |> length() == 1
  end

  test "the same guid on two different feeds does not collide" do
    feed_a = create_feed()
    feed_b = Dashboard.create_news_feed!(%{url: "https://example.com/other.xml", label: "Other"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed_a.id,
      guid: "shared-guid",
      title: "From A",
      url: "https://example.com/a"
    })

    Dashboard.create_news_item!(%{
      news_feed_id: feed_b.id,
      guid: "shared-guid",
      title: "From B",
      url: "https://example.com/b"
    })

    assert FamilyDashboard.NewsItem |> Ash.read!() |> length() == 2
  end

  describe "effective_time/1" do
    test "uses published_at when present" do
      feed = create_feed()

      published =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      item =
        Dashboard.create_news_item!(%{
          news_feed_id: feed.id,
          guid: "item-1",
          title: "Headline",
          url: "https://example.com/a",
          published_at: published
        })

      assert FamilyDashboard.NewsItem.effective_time(item) == published
    end

    test "falls back to inserted_at when published_at is nil" do
      feed = create_feed()

      item =
        Dashboard.create_news_item!(%{
          news_feed_id: feed.id,
          guid: "item-1",
          title: "Headline",
          url: "https://example.com/a"
        })

      assert FamilyDashboard.NewsItem.effective_time(item) == item.inserted_at
    end
  end
end
