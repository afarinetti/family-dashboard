defmodule FamilyDashboard.NewsTest do
  use ExUnit.Case, async: true

  alias FamilyDashboard.News

  defp rss(items_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <link>https://example.com</link>
        <description>Example</description>
        #{items_xml}
      </channel>
    </rss>
    """
  end

  defp atom(entries_xml) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Example Feed</title>
      #{entries_xml}
    </feed>
    """
  end

  describe "fetch_items/2 — RSS 2.0" do
    test "parses title, link, guid, and an RFC-822 pubDate" do
      xml =
        rss("""
        <item>
          <title>Council approves new park</title>
          <link>https://example.com/park</link>
          <guid>abc-123</guid>
          <pubDate>Wed, 02 Oct 2024 15:00:00 GMT</pubDate>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Council approves new park"
      assert item.url == "https://example.com/park"
      assert item.guid == "abc-123"
      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end

    test "parses an RFC-822 pubDate with a numeric UTC offset" do
      xml =
        rss("""
        <item>
          <title>Local edition</title>
          <link>https://example.com/local</link>
          <guid>local-1</guid>
          <pubDate>Wed, 02 Oct 2024 11:00:00 -0400</pubDate>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end

    test "decodes an HTML entity in a plain title" do
      xml =
        rss("""
        <item>
          <title>Storm &amp; Flood Watch</title>
          <link>https://example.com/storm</link>
          <guid>storm-1</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Storm & Flood Watch"
    end

    test "passes through a CDATA-wrapped title without double-escaping it" do
      # Per the XML spec, CDATA content is literal — entities are NOT decoded
      # inside it. Feeds that use CDATA embed already-raw characters directly
      # (unlike the plain-entity case above), so this must come out unchanged.
      xml =
        rss("""
        <item>
          <title><![CDATA[Storm & Flood Watch]]></title>
          <link>https://example.com/storm-cdata</link>
          <guid>storm-2</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.title == "Storm & Flood Watch"
    end

    test "falls back to the url as guid when the feed has none" do
      xml =
        rss("""
        <item>
          <title>No guid here</title>
          <link>https://example.com/no-guid</link>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.guid == "https://example.com/no-guid"
    end

    test "published_at is nil when pubDate is missing" do
      xml =
        rss("""
        <item>
          <title>No date</title>
          <link>https://example.com/no-date</link>
          <guid>no-date-1</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/rss.xml", plug: plug)

      assert item.published_at == nil
    end

    test "drops an item with no title or no link" do
      xml =
        rss("""
        <item>
          <link>https://example.com/no-title</link>
          <guid>x</guid>
        </item>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, []} = News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end
  end

  describe "fetch_items/2 — Atom" do
    test "parses title, link, id, and an ISO-8601 published timestamp" do
      xml =
        atom("""
        <entry>
          <title>Markets rise on jobs data</title>
          <link rel="alternate" href="https://example.com/markets"/>
          <id>urn:uuid:abc-123</id>
          <published>2024-10-02T15:00:00Z</published>
        </entry>
        """)

      plug = fn conn -> Req.Test.text(conn, xml) end
      assert {:ok, [item]} = News.fetch_items("https://feed.example/atom.xml", plug: plug)

      assert item.title == "Markets rise on jobs data"
      assert item.url == "https://example.com/markets"
      assert item.guid == "urn:uuid:abc-123"
      assert item.published_at == ~U[2024-10-02 15:00:00Z]
    end
  end

  describe "fetch_items/2 — transport and parse errors" do
    test "returns an error tuple on a non-200 response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, {:http_status, 500}} =
               News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end

    test "returns an error tuple on malformed XML" do
      plug = fn conn -> Req.Test.text(conn, "not xml at all") end

      assert {:error, _reason} = News.fetch_items("https://feed.example/rss.xml", plug: plug)
    end
  end
end
