import XCTest
@testable import Royal

final class RSSTests: XCTestCase {
    private func parse(_ xml: String, feed: String = "https://example.com/feed") throws -> RSSFetcher.Result {
        try RSSFetcher.parse(Data(xml.utf8), feedURL: URL(string: feed)!)
    }

    func testRSS2Items() throws {
        let result = try parse("""
            <?xml version="1.0"?>
            <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
              <channel>
                <title>Example</title>
                <image><title>Not the feed's title</title></image>
                <item>
                  <title>First</title>
                  <link>https://example.com/1</link>
                  <guid>https://example.com/1</guid>
                  <pubDate>Tue, 10 Nov 2026 22:04:05 +0000</pubDate>
                  <media:thumbnail url="https://example.com/1.jpg" width="640" height="320"/>
                </item>
                <item>
                  <title>Second</title>
                  <link>https://example.com/2</link>
                  <description>&lt;p&gt;Hi &lt;img src="/2.png" width="100" height="50"&gt;&lt;/p&gt;</description>
                </item>
                <item>
                  <title>Story</title>
                  <link>https://example.net/story</link>
                  <comments>https://news.ycombinator.com/item?id=42</comments>
                  <description>&lt;p&gt;Points: 150&lt;/p&gt;&lt;p&gt;# Comments: 7&lt;/p&gt;</description>
                </item>
              </channel>
            </rss>
            """)
        XCTAssertEqual(result.title, "Example")
        XCTAssertEqual(result.posts.map(\.title), ["First", "Second", "Story"])
        let first = result.posts[0]
        XCTAssertEqual(first.label, "Example")
        XCTAssertEqual(first.image, "https://example.com/1.jpg")
        XCTAssertEqual(first.imageAspect, 2)
        XCTAssertEqual(first.created, 1_794_348_245)
        XCTAssertTrue(first.id.hasPrefix("rss_"))
        XCTAssertEqual(first.commentsUrl, first.url)
        // A picture in the description, resolved against the item's link.
        XCTAssertEqual(result.posts[1].image, "https://example.com/2.png")
        XCTAssertEqual(result.posts[1].imageAspect, 2)
        // Hacker News stories keep their Hacker News ids, points and comments.
        let story = result.posts[2]
        XCTAssertEqual(story.id, "hn_42")
        XCTAssertEqual(story.score, 150)
        XCTAssertEqual(story.comments, 7)
        XCTAssertEqual(story.commentsUrl, "https://news.ycombinator.com/item?id=42")
    }

    func testIDsAreStableBetweenFetches() throws {
        let xml = "<rss><channel><item><title>A</title><link>https://example.com/a</link></item></channel></rss>"
        XCTAssertEqual(try parse(xml).posts[0].id, try parse(xml).posts[0].id)
        XCTAssertNotEqual(try parse(xml).posts[0].id, try parse(xml, feed: "https://other.example/feed").posts[0].id)
    }

    func testAtomWithXHTMLContent() throws {
        let result = try parse("""
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Atom Example</title>
              <entry>
                <title>Entry</title>
                <link rel="enclosure" href="https://example.org/e.mp3"/>
                <link rel="alternate" href="https://example.org/e"/>
                <id>tag:example.org,2026:e</id>
                <updated>2026-11-10T22:04:05Z</updated>
                <author><name>Someone</name></author>
                <content type="xhtml">
                  <div xmlns="http://www.w3.org/1999/xhtml">
                    <p>Look &amp; see</p>
                    <img src="https://example.org/pic.jpg" width="800" height="400"/>
                  </div>
                </content>
              </entry>
            </feed>
            """, feed: "https://example.org/atom.xml")
        XCTAssertEqual(result.title, "Atom Example")
        XCTAssertEqual(result.posts.count, 1)
        let entry = result.posts[0]
        XCTAssertEqual(entry.title, "Entry")
        XCTAssertEqual(entry.url, "https://example.org/e")
        XCTAssertEqual(entry.created, 1_794_348_245)
        XCTAssertEqual(entry.image, "https://example.org/pic.jpg")
        XCTAssertEqual(entry.imageAspect, 2)
    }

    func testAnUntitledXHTMLEntryIsNamedFromItsText() throws {
        let result = try parse("""
            <feed xmlns="http://www.w3.org/2005/Atom"><entry>
              <link href="https://example.org/note"/>
              <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Just a <b>short</b> note</p></div></content>
            </entry></feed>
            """)
        XCTAssertEqual(result.posts.first?.title, "Just a short note")
    }

    func testNotAFeed() {
        XCTAssertThrowsError(try parse("<html><body>Hello</body></html>"))
    }

    func testDates() {
        let expected = Date(timeIntervalSince1970: 1_794_348_245)
        XCTAssertEqual(RSSFetcher.date("Tue, 10 Nov 2026 22:04:05 GMT"), expected)
        XCTAssertEqual(RSSFetcher.date(" 2026-11-10T22:04:05Z "), expected)
        XCTAssertEqual(RSSFetcher.date("2026-11-10T22:04:05.000Z"), expected)
        XCTAssertNil(RSSFetcher.date("soon"))
    }

    // MARK: Finding feeds

    func testLinkedFeeds() {
        let html = #"""
            <html><head>
            <link rel="alternate" type="application/rss+xml" href="/feed.xml">
            <link type='application/atom+xml' rel='alternate' href='http://example.com/atom.xml'>
            <link rel="alternate" type="application/rss+xml" href="https://example.com/feed.xml">
            <link rel="stylesheet" href="/s.css">
            </head></html>
            """#
        let feeds = RSSFetcher.linkedFeeds(in: Data(html.utf8), page: URL(string: "https://example.com/blog/")!)
        XCTAssertEqual(feeds.map(\.absoluteString), ["https://example.com/feed.xml", "https://example.com/atom.xml"])
    }

    func testUsualFeeds() {
        let feeds = RSSFetcher.usualFeeds(for: URL(string: "https://example.com/blog/post.html?x=1")!).map(\.absoluteString)
        XCTAssertEqual(feeds.count, 12)
        XCTAssertEqual(feeds.first, "https://example.com/blog/feed")
        XCTAssertEqual(feeds[6], "https://example.com/feed")
        XCTAssertEqual(RSSFetcher.usualFeeds(for: URL(string: "https://example.com/")!).count, 6)
    }

    func testPastedAddresses() {
        XCTAssertEqual(RSSFeed.address("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(RSSFeed.address("  feed://example.com/rss\n")?.absoluteString, "https://example.com/rss")
        XCTAssertEqual(RSSFeed.address("feed:https://example.com/rss")?.absoluteString, "https://example.com/rss")
        XCTAssertEqual(RSSFeed.address("http://example.com/feed")?.absoluteString, "https://example.com/feed")
        XCTAssertNil(RSSFeed.address("localhost"))
        XCTAssertNil(RSSFeed.address("ftp://example.com/feed"))
    }

    // MARK: OPML

    func testOPMLRoundTrip() throws {
        let feeds = [RSSFeed(url: "https://example.com/feed", title: "A & <B>"),
                     RSSFeed(url: "https://example.org/rss?x=1&y=2", title: "Second")]
        XCTAssertEqual(try OPML.feeds(from: OPML.document(feeds)), feeds)
    }

    func testOPMLFoldersAndRepeats() throws {
        let opml = """
            <opml version="1.0"><body>
              <outline text="Folder">
                <outline text="One" xmlURL="http://example.com/one"/>
                <outline text="One again" xmlUrl="https://example.com/one"/>
              </outline>
              <outline title="Two" xmlUrl="https://example.com/two"/>
              <outline text="No feed"/>
            </body></opml>
            """
        let feeds = try OPML.feeds(from: Data(opml.utf8))
        XCTAssertEqual(feeds, [RSSFeed(url: "https://example.com/one", title: "One"),
                               RSSFeed(url: "https://example.com/two", title: "Two")])
        XCTAssertThrowsError(try OPML.feeds(from: Data("<rss/>".utf8)))
    }
}
