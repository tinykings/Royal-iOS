import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// A feed on the RSS tab, added in Settings or from an OPML file.
struct RSSFeed: Codable, Hashable, Identifiable {
    var url: String
    // The feed's own title, from its last fetch or the OPML file it came from.
    var title: String?

    var id: String { url }

    var name: String {
        if let title, !title.isEmpty { return title }
        return URL(string: url)?.host ?? url
    }

    // What turning RSS on starts with; each can be removed like any other feed.
    static let defaults = [
        RSSFeed(url: "https://hnrss.org/newest?points=150", title: "Hacker News: Newest"),
        RSSFeed(url: "https://krebsonsecurity.com/feed/", title: "Krebs on Security"),
        RSSFeed(url: "https://pitchfork.com/feed/reviews/best/albums/rss", title: "Best New Albums"),
        RSSFeed(url: "https://www.theverge.com/rss/index.xml", title: "The Verge"),
    ]

    // The list in Settings; the defaults until it's first changed.
    static func load() -> [RSSFeed] {
        guard let data = UserDefaults.standard.data(forKey: Preference.rssFeeds),
              let feeds = try? JSONDecoder().decode([RSSFeed].self, from: data) else { return defaults }
        return feeds
    }

    static func save(_ feeds: [RSSFeed]) {
        if let data = try? JSONEncoder().encode(feeds) {
            UserDefaults.standard.set(data, forKey: Preference.rssFeeds)
        }
    }

    // A pasted address as an https URL: feed:// and http:// links, and addresses
    // without a scheme, are read as https. Nil for anything that isn't a web address.
    static func address(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = string.lowercased()
        if lower.hasPrefix("feed://") {
            string = "https://" + string.dropFirst(7)
        } else if lower.hasPrefix("feed:") {
            string = String(string.dropFirst(5))
        }
        if string.lowercased().hasPrefix("http://") { string = "https://" + string.dropFirst(7) }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}

// MARK: Fetching

// Feeds are fetched natively rather than by sources.js: they can be on any host, and
// get none of the app's login cookies.
enum RSSFetcher {
    struct Result {
        let title: String?
        let posts: [FeedPost]
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL) async throws -> Result {
        let (data, _, status) = try await get(url)
        guard (200..<300).contains(status) else { throw FeedError.failed("HTTP \(status)") }
        return try await Task.detached { try parse(data, feedURL: url) }.value
    }

    private static func get(_ url: URL) async throws -> (data: Data, url: URL, status: Int) {
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.url ?? url, http?.statusCode ?? 0)
    }

    // A feed found by looking up an address, before it's added.
    struct Found: Identifiable, Hashable {
        let url: String
        let title: String?
        let itemCount: Int
        var id: String { url }

        var name: String { RSSFeed(url: url, title: title).name }
    }

    // The feeds at an address: the address itself when it's a feed; otherwise the
    // feeds a web page links in its head, or failing that, the usual feed addresses on
    // its site. Only addresses that load as feeds are returned.
    static func discover(_ url: URL) async throws -> [Found] {
        let (data, finalURL, status) = try await get(url)
        if (200..<300).contains(status),
           let result = try? await Task.detached(operation: { try parse(data, feedURL: url) }).value {
            return [Found(url: url.absoluteString, title: result.title, itemCount: result.posts.count)]
        }
        var candidates = (200..<300).contains(status) ? linkedFeeds(in: data, page: finalURL) : []
        if candidates.isEmpty { candidates = usualFeeds(for: finalURL) }
        let found = await withTaskGroup(of: (Int, Found?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    guard let result = try? await fetch(candidate) else { return (index, nil) }
                    return (index, Found(url: candidate.absoluteString, title: result.title, itemCount: result.posts.count))
                }
            }
            var out: [(Int, Found)] = []
            for await (index, found) in group { if let found { out.append((index, found)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !found.isEmpty else {
            let host = url.host ?? url.absoluteString
            // Sites behind a bot check (Cloudflare's "Just a moment…") answer apps with that
            // page instead of their own, though their feeds may still load.
            if isBotCheck(data, status: status) {
                throw FeedError.failed("\(host) only shows its pages to web browsers, so Royal can't look for feeds there. Paste the feed's own address instead; it may still load.")
            }
            throw FeedError.failed("No RSS or Atom feed found at \(host).")
        }
        return found
    }

    private static func isBotCheck(_ data: Data, status: Int) -> Bool {
        guard [403, 429, 503].contains(status) else { return false }
        let page = String(decoding: data.prefix(20_000), as: UTF8.self)
        return ["<title>Just a moment...</title>", "challenge-platform", "cf-chl", "Attention Required!"].contains { page.contains($0) }
    }

    // <link rel="alternate" type="application/rss+xml" href="…"> and its Atom and RDF
    // kin, in page order, without repeats.
    static func linkedFeeds(in data: Data, page: URL) -> [URL] {
        let html = String(decoding: data.prefix(500_000), as: UTF8.self)
        let tag = /<link\b[^>]*>/.ignoresCase()
        let attribute = /([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        var seen = Set<String>()
        var feeds: [URL] = []
        for match in html.matches(of: tag) {
            var attributes: [String: String] = [:]
            for pair in match.output.matches(of: attribute) {
                let value = pair.output.2 ?? pair.output.3 ?? pair.output.4 ?? ""
                attributes[pair.output.1.lowercased()] = String(value).replacingOccurrences(of: "&amp;", with: "&")
            }
            let rel = attributes["rel"]?.lowercased().split(separator: " ") ?? []
            let type = attributes["type"]?.lowercased() ?? ""
            guard rel.contains("alternate"),
                  ["application/rss+xml", "application/atom+xml", "application/rdf+xml"].contains(type),
                  let href = attributes["href"], let resolved = URL(string: href, relativeTo: page)?.absoluteURL,
                  let feed = RSSFeed.address(resolved.absoluteString),
                  seen.insert(feed.absoluteString).inserted else { continue }
            feeds.append(feed)
        }
        return feeds
    }

    // Where sites commonly keep a feed, under the page's folder and the site's root.
    static func usualFeeds(for page: URL) -> [URL] {
        guard var root = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return [] }
        root.query = nil
        root.fragment = nil
        var folder = root.path
        if !folder.hasSuffix("/") { folder = folder.contains(".") ? String(folder[...(folder.lastIndex(of: "/") ?? folder.startIndex)]) : folder + "/" }
        var folders = ["/"]
        if folder != "/" { folders.insert(folder, at: 0) }
        let names = ["feed", "rss", "feed.xml", "rss.xml", "atom.xml", "index.xml"]
        var seen = Set<String>()
        return folders.flatMap { folder in
            names.compactMap { name -> URL? in
                root.path = folder + name
                guard let url = root.url, seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
        }
    }

    // RSS 2.0, RSS 1.0 (RDF) and Atom.
    static func parse(_ data: Data, feedURL: URL) throws -> Result {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isFeed else {
            throw FeedError.failed("Not an RSS or Atom feed")
        }
        let label = reader.title.flatMap { $0.isEmpty ? nil : $0 } ?? feedURL.host ?? "RSS"
        let posts = reader.items.compactMap { post(from: $0, feedURL: feedURL, label: label) }
        return Result(title: reader.title, posts: posts)
    }

    // Descriptions can be whole articles; this keeps the cache and synced saves small.
    private static let summaryLimit = 20_000

    private static func post(from item: FeedReader.Item, feedURL: URL, label: String) -> FeedPost? {
        let guidLink = item.guid.flatMap(httpURL)
        guard let url = item.link.flatMap(httpURL) ?? guidLink ?? item.comments.flatMap(httpURL) else { return nil }
        let summary = (item.content ?? item.summary)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainSummary = summary.map(plainText)
        guard let shownTitle = title.flatMap({ $0.isEmpty ? nil : $0 })
                ?? plainSummary.map({ String($0.prefix(120)) }).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        let comments = item.comments.flatMap(httpURL)
        // The feed's own image for the item, else the first picture in its description.
        let image = item.image.flatMap { picture in imageURL(picture, base: url).map { (url: $0, aspect: item.imageAspect) } }
            ?? summary.flatMap { firstPicture(in: $0, base: url) }
        // Hacker News stories keep the ids they had from Hacker News itself, so what was
        // saved and seen there carries over.
        let id = [item.comments, item.guid, url].compactMap { $0 }.lazy.compactMap(hackerNewsID).first.map { "hn_\($0)" }
            ?? "rss_" + SHA256.hash(data: Data((feedURL.absoluteString + " " + (item.guid ?? url)).utf8))
                .prefix(12).map { String(format: "%02x", $0) }.joined()
        // hnrss lists points and comments in each description.
        let score = plainSummary.flatMap { number(after: "Points:", in: $0) }
        // Feeds without comments of their own often still say "0" in slash:comments.
        let commentCount = item.commentCount.flatMap { $0 > 0 ? $0 : nil }
            ?? plainSummary.flatMap { number(after: "# Comments:", in: $0) }
        return FeedPost(source: .rss, id: id, title: shownTitle, url: url, commentsUrl: comments ?? url, label: label,
                        score: score, comments: commentCount, created: item.date.flatMap(date)?.timeIntervalSince1970,
                        image: image?.url, imageAspect: image?.aspect, videoId: nil, published: nil,
                        publishedAt: nil, nsfw: nil,
                        summary: summary.flatMap { $0.isEmpty ? nil : String($0.prefix(summaryLimit)) })
    }

    private static func httpURL(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return trimmed
    }

    // Pictures load over https only; http ones are tried as https.
    private static func imageURL(_ string: String, base: String) -> String? {
        let trimmed = decodeEntities(string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("data:"),
              let resolved = URL(string: trimmed, relativeTo: URL(string: base))?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { return nil }
        components.scheme = "https"
        return components.url?.absoluteString
    }

    // &amp;, &#038; and &#x26; and the like, as HTML attributes write them.
    private static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        var out = ""
        var rest = Substring(string)
        while let start = rest.firstIndex(of: "&") {
            out += rest[..<start]
            let after = rest[rest.index(after: start)...]
            if let end = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<end]
                let scalar: String? = if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    named[name.lowercased()]
                }
                if let scalar {
                    out += scalar
                    rest = after[after.index(after: end)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    // The first <img> in an item's HTML that isn't a tracking pixel or a tiny icon,
    // with its shape when the tag gives both width and height.
    private static func firstPicture(in html: String, base: String) -> (url: String, aspect: Double?)? {
        let tag = /<img\b[^>]*>/.ignoresCase()
        let attribute = /([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        for match in html.prefix(200_000).matches(of: tag) {
            var attributes: [String: String] = [:]
            for pair in match.output.matches(of: attribute) {
                attributes[pair.output.1.lowercased()] = String(pair.output.2 ?? pair.output.3 ?? pair.output.4 ?? "")
            }
            let width = attributes["width"].flatMap { Double($0) }
            let height = attributes["height"].flatMap { Double($0) }
            if let width, width < 40 { continue }
            if let height, height < 40 { continue }
            guard let src = attributes["src"], let url = imageURL(src, base: base) else { continue }
            let aspect = width.flatMap { width in height.map { width / $0 } }
            return (url, aspect)
        }
        return nil
    }

    private static func hackerNewsID(_ string: String) -> String? {
        guard let components = URLComponents(string: string), components.host == "news.ycombinator.com",
              components.path == "/item", let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func number(after label: String, in text: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        return Int(text[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber })
    }

    private static let rfc822: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss", "EEE, d MMM yy HH:mm:ss Z",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    private static func date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        return rfc822.lazy.compactMap { $0.date(from: trimmed) }.first
    }
}

// Collects a feed's title and items as XMLParser reads it.
private final class FeedReader: NSObject, XMLParserDelegate {
    struct Item {
        var title: String?
        var link: String?
        var guid: String?
        var comments: String?
        var summary: String?
        var content: String?
        var date: String?
        var image: String?
        var imageAspect: Double?
        // The width of `image`, so the largest of several offered is kept.
        var imageWidth: Double?
        var commentCount: Int?
    }

    private(set) var isFeed = false
    private(set) var title: String?
    private(set) var items: [Item] = []
    private var current: Item?
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        if path.isEmpty { isFeed = ["rss", "feed", "rdf:rdf"].contains(name) }
        path.append(name)
        text = ""
        if name == "item" || name == "entry" {
            current = Item()
            return
        }
        guard current != nil else { return }
        switch name {
        case "link":
            // Atom: the alternate link is the page.
            if let href = attributes["href"], ["alternate", nil].contains(attributes["rel"]), current?.link == nil {
                current?.link = href
            }
        case "media:thumbnail", "media:content", "enclosure":
            let type = attributes["type"] ?? ""
            guard let url = attributes["url"], !url.isEmpty else { break }
            // media:content often gives no type, only an image's address.
            let looksLikeImage = type.isEmpty && attributes["medium"] == nil
                && url.range(of: #"\.(jpe?g|png|gif|webp|avif)(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let isImage = name == "media:thumbnail" || type.hasPrefix("image/") || attributes["medium"] == "image" || looksLikeImage
            guard isImage else { break }
            let width = attributes["width"].flatMap(Double.init)
            let height = attributes["height"].flatMap(Double.init)
            // The first image offered, or a wider one after it.
            if current?.image == nil || (width ?? 0) > (current?.imageWidth ?? .infinity) {
                current?.image = url
                current?.imageWidth = width
                current?.imageAspect = width.flatMap { width in height.flatMap { $0 > 0 ? width / $0 : nil } }
            }
        case "itunes:image":
            if current?.image == nil, let url = attributes["href"], !url.isEmpty { current?.image = url }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        path.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard var item = current else {
            // The channel's or feed's own title, not its image's.
            if name == "title", title == nil, ["channel", "feed"].contains(path.last) { title = value }
            return
        }
        // Only the item's own fields, not those of an Atom entry's nested source or author.
        let parent = path.last
        let direct = parent == "item" || parent == "entry"
        switch name {
        case "item", "entry":
            items.append(item)
            current = nil
            return
        case "title" where direct: item.title = value
        case "link" where direct && !value.isEmpty: item.link = value
        case "guid" where direct, "id" where direct: item.guid = value.isEmpty ? nil : value
        case "comments" where direct: item.comments = value.isEmpty ? nil : value
        case "description" where direct, "summary" where direct: item.summary = value
        case "content:encoded" where direct, "content" where direct: item.content = value.isEmpty ? nil : value
        case "pubdate", "published", "dc:date": if !value.isEmpty { item.date = value }
        case "updated": if item.date == nil, !value.isEmpty { item.date = value }
        case "slash:comments": item.commentCount = Int(value)
        default: break
        }
        current = item
    }
}

// MARK: OPML

extension UTType {
    static let opml = UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml
}

enum OPML {
    // Every outline with a feed address, folders included, without repeats.
    static func feeds(from data: Data) throws -> [RSSFeed] {
        let reader = OutlineReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isOPML else { throw FeedError.failed("That file isn't an OPML file.") }
        var seen = Set<String>()
        return reader.feeds.compactMap { feed in
            guard let url = RSSFeed.address(feed.url), seen.insert(url.absoluteString).inserted else { return nil }
            return RSSFeed(url: url.absoluteString, title: feed.title)
        }
    }

    static func document(_ feeds: [RSSFeed]) -> Data {
        func escape(_ string: String) -> String {
            string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let outlines = feeds.map { feed in
            let name = escape(feed.name)
            return "    <outline type=\"rss\" text=\"\(name)\" title=\"\(name)\" xmlUrl=\"\(escape(feed.url))\"/>"
        }
        let created = Date().formatted(.iso8601)
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head>
                <title>Royal RSS Feeds</title>
                <dateCreated>\(created)</dateCreated>
              </head>
              <body>
            \(outlines.joined(separator: "\n"))
              </body>
            </opml>

            """.utf8)
    }

    private final class OutlineReader: NSObject, XMLParserDelegate {
        private(set) var isOPML = false
        private(set) var feeds: [RSSFeed] = []
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if depth == 0 { isOPML = elementName.lowercased() == "opml" }
            depth += 1
            guard elementName.lowercased() == "outline" else { return }
            // Attribute names vary in case between apps.
            let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
            guard let url = lowered["xmlurl"], !url.isEmpty else { return }
            let title = [lowered["title"], lowered["text"]].compactMap { $0 }.first { !$0.isEmpty }
            feeds.append(RSSFeed(url: url, title: title))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            depth -= 1
        }
    }
}

struct OPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.opml]
    let data: Data

    init(feeds: [RSSFeed]) {
        data = OPML.document(feeds)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: Managing feeds

// The feed list, from Settings or the RSS tab's header: add by pasting an address,
// swipe to remove, and import or export OPML.
struct RSSFeedsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var address = ""
    @State private var searching = false
    @State private var addError: String?
    // The feeds the last lookup found, for picking which to add.
    @State private var found: [RSSFetcher.Found] = []
    @State private var importing = false
    @State private var exporting = false
    @State private var notice: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        List {
            Section {
                TextField("Feed address", text: $address, prompt: Text("Paste a feed address"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($addressFocused)
                    .onSubmit(find)
                    .onChange(of: address) {
                        found = []
                        addError = nil
                    }
                Button(action: find) {
                    HStack {
                        Text(searching ? "Looking for Feeds…" : "Find Feeds")
                        if searching {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(searching || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add a Feed")
            } footer: {
                if let addError {
                    Text(addError).foregroundStyle(.red)
                } else {
                    Text("Paste a feed's address, or a website's, to look for its feeds.")
                }
            }
            if !found.isEmpty {
                Section {
                    ForEach(found) { feed in
                        let added = store.rssFeeds.contains { $0.url == feed.url }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.name)
                                Text(feed.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(feed.itemCount == 1 ? "1 item" : "\(feed.itemCount) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                withAnimation { store.addRSSFeed(feed) }
                            } label: {
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.borderless)
                            .disabled(added)
                            .accessibilityLabel(added ? "Added" : "Add \(feed.name)")
                        }
                    }
                } header: {
                    Text(found.count == 1 ? "Found 1 Feed" : "Found \(found.count) Feeds")
                }
            }
            Section {
                if store.rssFeeds.isEmpty {
                    Text("No feeds")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rssFeeds) { feed in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name)
                        Text(feed.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let error = store.rssFeedErrors[feed.url] {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = feed.url
                        } label: {
                            Label("Copy Address", systemImage: "doc.on.doc")
                        }
                    }
                }
                .onDelete { store.removeRSSFeeds(at: $0) }
                .onMove { store.moveRSSFeeds(from: $0, to: $1) }
            } header: {
                Text("Feeds")
            } footer: {
                if !store.rssFeeds.isEmpty {
                    Text("Swipe left on a feed to remove it.")
                }
            }
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import OPML File", systemImage: "square.and.arrow.down")
                }
                Button {
                    exporting = true
                } label: {
                    Label("Export OPML File", systemImage: "square.and.arrow.up")
                }
                .disabled(store.rssFeeds.isEmpty)
            } header: {
                Text("OPML")
            } footer: {
                Text("Importing adds the file's feeds that aren't in the list yet. Exporting saves the list as an OPML file for other RSS apps.")
            }
        }
        .navigationTitle("RSS Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.rssFeeds.isEmpty { EditButton() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.opml, .xml]) { result in
            importFile(result)
        }
        .fileExporter(isPresented: $exporting, document: OPMLDocument(feeds: store.rssFeeds),
                      contentType: .opml, defaultFilename: "Royal RSS Feeds") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
        .alert(notice ?? "", isPresented: Binding { notice != nil } set: { if !$0 { notice = nil } }) {
            Button("OK", role: .cancel) {}
        }
    }

    private func find() {
        let text = address
        guard !searching, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        addError = nil
        found = []
        addressFocused = false
        Task {
            do {
                let results = try await store.findRSSFeeds(text)
                // Unless the address changed while looking.
                if address == text { found = results }
            } catch {
                if address == text { addError = error.localizedDescription }
            }
            searching = false
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let feeds = try OPML.feeds(from: Data(contentsOf: url))
            let added = store.importRSSFeeds(feeds)
            notice = switch (feeds.count, added) {
            case (0, _): "That file has no feeds."
            case (_, 0): "Every feed in that file is already in the list."
            case (_, 1): "Added 1 feed."
            default: "Added \(added) feeds."
            }
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: Description

// An RSS item's description, from its feed. Feeds' HTML shows without scripts, and
// its links open in a Safari view.
struct RSSDescriptionView: View {
    let post: FeedPost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DescriptionWebView(html: Self.page(post), baseURL: URL(string: post.url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(post.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            if let url = URL(string: post.url) { SafariView.present(url) }
                        } label: {
                            Label("Open Link", systemImage: "link")
                                .labelStyle(.titleAndIcon)
                        }
                        Spacer()
                        if post.commentsUrl != post.url {
                            Button {
                                if let url = URL(string: post.commentsUrl) { SafariView.present(url) }
                            } label: {
                                Label("Comments", systemImage: "bubble.left.and.bubble.right")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
        }
    }

    private static func page(_ post: FeedPost) -> String {
        func escape(_ string: String) -> String {
            string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let date = post.created.map {
            "<p class=meta>\(escape(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)))</p>"
        } ?? ""
        let body = post.summary ?? "<p class=meta>This post has no description.</p>"
        return """
            <!doctype html>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'">
            <style>
            :root { color-scheme: light dark; }
            body { font: -apple-system-body; margin: 16px 16px 40px; overflow-wrap: anywhere; line-height: 1.45; }
            h1 { font: -apple-system-title2; font-weight: 700; margin: 0 0 4px; }
            .meta { color: gray; font: -apple-system-footnote; margin: 0 0 16px; }
            img, video { max-width: 100%; height: auto; }
            pre { white-space: pre-wrap; }
            a { color: #b8860b; }
            </style>
            <h1>\(escape(post.title))</h1>
            \(date)
            \(body)
            """
    }
}

private struct DescriptionWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Feeds' pages get no cookies from the app's logins.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        // Only the description itself loads here; anything after it is a link to open.
        private var loaded = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !loaded, navigationAction.navigationType == .other else {
                if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") {
                    Task { @MainActor in SafariView.present(url) }
                }
                decisionHandler(.cancel)
                return
            }
            loaded = true
            decisionHandler(.allow)
        }
    }
}
