defmodule FamilyDashboard.NewsFeedTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  test "creates a feed with defaults" do
    assert {:ok, feed} =
             Dashboard.create_news_feed(%{url: "https://example.com/rss.xml", label: "Example"})

    assert feed.url == "https://example.com/rss.xml"
    assert feed.label == "Example"
    assert feed.enabled == true
    assert feed.last_fetched_at == nil
    assert feed.last_error == nil
  end

  test "requires url and label" do
    assert {:error, _} = Dashboard.create_news_feed(%{})
  end

  test "can be disabled and updated" do
    feed = Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})

    assert {:ok, updated} = Dashboard.update_news_feed(feed, %{enabled: false})
    assert updated.enabled == false
  end

  test "has_many :items loads its news items" do
    feed = Dashboard.create_news_feed!(%{url: "https://example.com/rss.xml", label: "Example"})

    Dashboard.create_news_item!(%{
      news_feed_id: feed.id,
      guid: "item-1",
      title: "Headline",
      url: "https://example.com/a"
    })

    loaded = Ash.load!(feed, :items)
    assert length(loaded.items) == 1
  end
end
