import CraCore
import Foundation
import Testing

struct RSSFeedTests {
    @Test func parsesRSS2WithCDATAEntitiesAndSorting() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title><![CDATA[Engineering &amp; Design]]></title>
            <link>https://example.test/</link>
            <item>
              <title>Older Post &amp; Notes &#8212; Part 1</title>
              <link>/posts/older</link>
              <guid>post-1</guid>
              <dc:creator>Alice</dc:creator>
              <pubDate>Tue, 03 Nov 2026 10:00:00 GMT</pubDate>
            </item>
            <item>
              <title><![CDATA[Newer <em>Release</em>]]></title>
              <link>https://example.test/posts/newer</link>
              <guid isPermaLink="false">post-2</guid>
              <author>Bob</author>
              <pubDate>Fri, 06 Nov 2026 12:30:00 +0200</pubDate>
            </item>
            <item>
              <title>Duplicate URL</title>
              <link>https://EXAMPLE.TEST/posts/newer</link>
              <pubDate>Sat, 07 Nov 2026 12:00:00 GMT</pubDate>
            </item>
            <item>
              <title>Unsafe Link</title>
              <link>javascript:alert(1)</link>
            </item>
          </channel>
        </rss>
        """
        let base = try #require(URL(string: "https://example.test/feed.xml"))
        let feed = try #require(RSSFeed.parse(xml, baseURL: base))
        #expect(feed.title == "Engineering & Design")
        #expect(feed.siteURL == "https://example.test/")
        #expect(feed.items.count == 2)
        #expect(feed.items.map(\.title) == ["Newer Release", "Older Post & Notes — Part 1"])
        #expect(feed.items.map(\.url) == ["https://example.test/posts/newer", "https://example.test/posts/older"])
        #expect(feed.items.map(\.author) == ["Bob", "Alice"])
        #expect(feed.items[0].publishedAt != nil && feed.items[1].publishedAt != nil)
        #expect(try #require(feed.items[0].publishedAt) > #require(feed.items[1].publishedAt))
    }

    @Test func parsesAtomEntriesWithRelativeLinksAndDates() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Updates</title>
          <link rel="self" href="/atom.xml"/>
          <link rel="alternate" href="https://example.test/"/>
          <entry>
            <title type="html">&lt;b&gt;First&lt;/b&gt; Entry</title>
            <link rel="enclosure" href="https://example.test/audio.mp3"/>
            <link rel="alternate" href="/entries/first"/>
            <id>urn:uuid:1</id>
            <updated>2026-11-01T08:00:00Z</updated>
            <author><name>Carol</name></author>
          </entry>
          <entry>
            <title>Second Entry</title>
            <link href="/entries/second"/>
            <id>urn:uuid:2</id>
            <published>2026-11-05T15:00:00.250+0100</published>
          </entry>
        </feed>
        """
        let base = try #require(URL(string: "https://example.test/atom.xml"))
        let feed = try #require(RSSFeed.parse(xml, baseURL: base))
        #expect(feed.title == "Atom Updates")
        #expect(feed.siteURL == "https://example.test/")
        #expect(feed.items.map(\.title) == ["Second Entry", "First Entry"])
        #expect(feed.items.map(\.url) == ["https://example.test/entries/second", "https://example.test/entries/first"])
        #expect(feed.items[1].author == "Carol")
    }

    @Test func discoversFeedLinksFromHTMLWithPriorityAndRelativeResolution() throws {
        let html = """
        <!doctype html>
        <html>
        <head>
          <!-- <link rel="alternate" type="application/rss+xml" href="/commented-out.xml"> -->
          <link rel="stylesheet" href="/app.css">
          <link rel="alternate" type="text/xml" title="XML Feed" href="/xml-feed">
          <link rel='alternate' type='application/atom+xml; charset=utf-8' title='Atom &amp; News' href='/atom.xml'>
          <link rel="alternate" type="application/rss+xml" title="Main RSS" href="https://example.test/rss.xml">
          <link rel="alternate" type="application/rss+xml" href="/rss.xml">
          <link rel="alternate" type="application/rss+xml" href="javascript:void(0)">
        </head>
        </html>
        """
        let base = try #require(URL(string: "https://example.test/blog/"))
        let discovered = RSSFeed.discoverFeedURLs(in: html, baseURL: base)
        #expect(discovered == [
            RSSDiscoveredFeed(url: "https://example.test/atom.xml", title: "Atom & News", kind: .atom),
            RSSDiscoveredFeed(url: "https://example.test/rss.xml", title: "Main RSS", kind: .rss),
            RSSDiscoveredFeed(url: "https://example.test/xml-feed", title: "XML Feed", kind: .xml)
        ])
    }

    @Test func conditionalHeadersAndValidatorsRoundTripCaseInsensitively() {
        let validators = RSSFeed.cacheValidators(from: [
            "ETag": " \"abc-123\" ",
            "last-modified": "Fri, 06 Nov 2026 12:00:00 GMT",
            "Content-Type": "application/rss+xml"
        ])
        #expect(validators.etag == "\"abc-123\"")
        #expect(validators.lastModified == "Fri, 06 Nov 2026 12:00:00 GMT")

        let requestHeaders = RSSFeed.conditionalHeaders(etag: validators.etag, lastModified: validators.lastModified)
        #expect(requestHeaders == [
            "If-None-Match": "\"abc-123\"",
            "If-Modified-Since": "Fri, 06 Nov 2026 12:00:00 GMT"
        ])
        #expect(RSSFeed.conditionalHeaders(etag: "  ", lastModified: nil).isEmpty)
    }

    @Test func normalizesFeedAddressesWithQueryStrings() {
        #expect(RSSFeed.normalizeAddress("example.com/feed.xml") == "https://example.com/feed.xml")
        #expect(RSSFeed.normalizeAddress("https://www.youtube.com/feeds/videos.xml?channel_id=UC123") == "https://www.youtube.com/feeds/videos.xml?channel_id=UC123")
        #expect(RSSFeed.normalizeAddress("http://example.com:80/rss?page=1#top") == nil)
        #expect(RSSFeed.normalizeAddress("https://user:pass@example.com/feed.xml") == nil)
    }

    @Test func rejectsHTMLAndMalformedXMLAsFeeds() {
        #expect(RSSFeed.parse("<html><body>Not a feed</body></html>") == nil)
        #expect(RSSFeed.parse("<rss><channel><item></rss>") == nil)
        #expect(RSSFeed.parse("") == nil)
    }
}
