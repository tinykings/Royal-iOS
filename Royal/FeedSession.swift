import CryptoKit
import UIKit
import WebKit

enum FeedSource: String, Codable, CaseIterable, Identifiable {
    case reddit, rss, youtube

    var id: String { rawValue }

    // Also takes "hn": Hacker News, which RSS replaced, as saved posts, settings and
    // synced records name it.
    init?(stored: String) {
        self.init(rawValue: stored == "hn" ? FeedSource.rss.rawValue : stored)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let source = FeedSource(stored: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown source \(raw)")
        }
        self = source
    }

    var title: String {
        switch self {
        case .reddit: "Reddit"
        case .rss: "RSS"
        case .youtube: "YouTube"
        }
    }

    // Where to log in; RSS needs no account.
    var loginURL: URL? {
        switch self {
        case .reddit: URL(string: "https://www.reddit.com/login/")!
        case .youtube: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube"
            + "&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3D%252Ffeed%252Fsubscriptions")!
        case .rss: nil
        }
    }
}

// Mirrors the post shape sources.js produces for every source.
struct FeedPost: Codable, Identifiable {
    let source: FeedSource
    let id: String
    let title: String
    let url: String
    let commentsUrl: String
    let label: String
    let score: Int?
    let comments: Int?
    let created: Double?
    let image: String?
    // Reddit only: the image's width over height, when Reddit reports it.
    let imageAspect: Double?
    let videoId: String?
    let published: String?
    // YouTube only: latest time the video could have been published, from its age text.
    let publishedAt: Double?
    // Reddit only: marked NSFW. Missing on posts fetched while NSFW was always left out.
    let nsfw: Bool?
    // YouTube only: the channel the video is from, when the page links it.
    var channelId: String? = nil
    // RSS only: the item's description (or full content), as the feed's HTML.
    var summary: String? = nil
}

enum FeedError: LocalizedError {
    case notLoggedIn(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let message): "Not logged in (\(message))"
        case .failed(let message): message
        }
    }
}

// A cookie that keeps a source logged in, and when it runs out (nil: when the browser
// session ends).
struct LoginCookie: Identifiable, Equatable {
    let name: String
    let expires: Date?
    var id: String { name }

    // What the cookie is for, in plain words, since the names mean little to most people.
    var kind: String {
        switch name {
        case "reddit_session", "LOGIN_INFO": "Login cookie"
        case "__Secure-1PSIDTS": "Google session cookie"
        default: "Cookie"
        }
    }
}

// One browser profile for the app: login pages store cookies here,
// and native requests read them back.
enum WebProfile {
    static let safariVersion = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"

    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // WKWebView omits Mobile Safari's user-agent suffix; add it so sites see Safari.
        config.applicationNameForUserAgent = "Version/\(safariVersion).0 Mobile/15E148 Safari/604.1"
        return config
    }
}

// Runs sources.js in a hidden blank page. Reddit blocks .json fetches
// made by page scripts, so sources.js's fetch() is routed to URLSession with the login
// cookies.
@MainActor
final class FeedSession: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    // Hosts sources.js may reach.
    private static let allowedHosts: Set<String> = ["www.reddit.com", "www.youtube.com"]
    // YouTube serves its mobile site, with different page data, to phone user agents.
    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/\(WebProfile.safariVersion).0 Safari/605.1.15"

    private let webView = WKWebView(frame: .zero, configuration: WebProfile.configuration())
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    private var cookieStore: WKHTTPCookieStore { webView.configuration.websiteDataStore.httpCookieStore }
    private var userAgent: String?
    private var loaded = false
    // Bumped whenever the page is reloaded, so concurrent failures reload it only once.
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []

    private lazy var sourcesScript: String = {
        guard let url = Bundle.main.url(forResource: "sources", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // sources.js is an ES module; drop `export` so it runs inside a plain function.
        let body = text.replacingOccurrences(of: "(?m)^export\\s+", with: "", options: .regularExpression)
        return """
            globalThis.Royal ??= (() => {
            const fetch = async (url) => {
              const r = await window.webkit.messageHandlers.nativeFetch.postMessage(String(url));
              const empty = [101, 204, 205, 304].includes(r.status);
              const res = new Response(empty ? null : r.body, { status: r.status });
              Object.defineProperty(res, "url", { value: r.url });
              return res;
            };
            \(body)
            return { fetchReddit, fetchSubscribedSubreddits, fetchYouTube, NotLoggedInError };
            })();

            """
    }()

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "nativeFetch")
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
            if waiters.count == 1 {
                webView.loadHTMLString("<!doctype html><title>Royal</title>", baseURL: nil)
            }
        }
        userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
    }

    private func finishLoading(_ error: Error?) {
        loaded = error == nil
        let pending = waiters
        waiters = []
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    // iOS can kill the hidden page's process, typically while the app is in the background.
    // Scripts then fail until the page is loaded again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        discardPage()
    }

    private func discardPage() {
        guard waiters.isEmpty else { return }
        loaded = false
        generation += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let string = message.body as? String, let url = URL(string: string), url.scheme == "https",
              let host = url.host, Self.allowedHosts.contains(host) else {
            replyHandler(nil, "Blocked request to \(message.body)")
            return
        }
        Task {
            do {
                let (status, body, finalURL) = try await nativeFetch(url)
                replyHandler(["status": status, "body": body, "url": finalURL], nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host else { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return (host == domain || host.hasSuffix("." + domain))
            && url.path.hasPrefix(cookie.path)
            && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    private func nativeFetch(_ url: URL) async throws -> (Int, String, String) {
        var request = URLRequest(url: url)
        let cookies = await cookieStore.allCookies().filter { Self.cookie($0, matches: url) }
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let agent = url.host == "www.youtube.com" ? Self.desktopUserAgent : userAgent
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        #if DEBUG
        NSLog("Royal fetch %d %@ -> %@ %@", http?.statusCode ?? 0, url.absoluteString,
              http?.url?.absoluteString ?? "", String(decoding: data.prefix(80), as: UTF8.self))
        #endif
        // Keep refreshed session cookies (Reddit rotates token_v2) in the shared profile.
        if let http, let fields = http.allHeaderFields as? [String: String] {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                await cookieStore.setCookie(cookie)
            }
        }
        return (http?.statusCode ?? 0, String(decoding: data, as: UTF8.self), http?.url?.absoluteString ?? url.absoluteString)
    }

    private func run(_ body: String, _ arguments: [String: Any] = [:], retry: Bool = true) async throws -> Any? {
        try await ensureLoaded()
        let started = generation
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
        } catch let error as WKError where retry && Self.pageLost(error) {
            // The page's process went away under us (it reports this as an unsupported
            // result type); load a fresh page and try once more.
            if generation == started { discardPage() }
            return try await run(body, arguments, retry: false)
        }
    }

    private static func pageLost(_ error: WKError) -> Bool {
        [.javaScriptResultTypeIsUnsupported, .webContentProcessTerminated, .webViewInvalidated].contains(error.code)
    }

    func isLoggedIn(_ source: FeedSource) async -> Bool {
        let cookies = await cookieStore.allCookies()
        switch source {
        case .reddit: return cookies.contains { $0.name == "reddit_session" && $0.domain.hasSuffix("reddit.com") }
        case .youtube: return cookies.contains { $0.name == "LOGIN_INFO" && $0.domain.hasSuffix("youtube.com") }
        case .rss: return true
        }
    }

    // The cookies worth watching for the source's login. On YouTube, __Secure-1PSIDTS
    // can run out well before LOGIN_INFO, and losing it signs the user out.
    func loginCookies(_ source: FeedSource) async -> [LoginCookie] {
        let (domain, names): (String, [String]) = switch source {
        case .reddit: ("reddit.com", ["reddit_session"])
        case .youtube: ("youtube.com", ["LOGIN_INFO", "__Secure-1PSIDTS"])
        case .rss: ("", [])
        }
        let cookies = await cookieStore.allCookies()
        return names.compactMap { name in
            cookies.first { $0.name == name && $0.domain.hasSuffix(domain) }
                .map { LoginCookie(name: name, expires: $0.expiresDate) }
        }
    }

    // Removes the site data holding the source's login. YouTube signs in through Google,
    // whose own cookies would sign it straight back in, so those go too.
    func logOut(_ source: FeedSource) async {
        let domains: Set<String> = switch source {
        case .reddit: ["reddit.com"]
        case .youtube: ["youtube.com", "google.com"]
        case .rss: []
        }
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { domains.contains($0.displayName) }
        await store.removeData(ofTypes: types, for: records)
        // Cookies set natively from fetch responses can outlive the records; clear them directly.
        for cookie in await cookieStore.allCookies() {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if domains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                await cookieStore.deleteCookie(cookie)
            }
        }
    }

    // Debug readout: which session cookies exist, and how each endpoint answers.
    func diagnostics() async -> String {
        var lines: [String] = []
        let cookies = await cookieStore.allCookies().filter { $0.domain.contains("reddit") || $0.domain.contains("youtube") }
        lines.append("Cookies: " + cookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ", "))
        try? await ensureLoaded()
        for url in ["https://www.reddit.com/subreddits/mine/subscriber.json?limit=1", "https://www.reddit.com/best.json?limit=1",
                    "https://www.youtube.com/feed/subscriptions"] {
            do {
                let (status, body, finalURL) = try await nativeFetch(URL(string: url)!)
                let loggedOut = body.contains("\"LOGGED_IN\":false") ? " (logged out)" : ""
                lines.append("\(status) \(url) -> \(finalURL)\(loggedOut) \(body.prefix(40))")
            } catch {
                lines.append("ERR \(url) \(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Subscribes to, or unsubscribes from, a YouTube channel as the logged-in account, the way
    // YouTube's own site does. Like the feeds, this relies on YouTube's undocumented web API.
    func setSubscribed(channelId: String, _ subscribed: Bool) async throws {
        guard channelId.range(of: "^UC[\\w-]{22}$", options: .regularExpression) != nil else {
            throw FeedError.failed("Unknown YouTube channel")
        }
        let origin = "https://www.youtube.com"
        try await ensureLoaded()
        // The page's settings say which signed-in account and session the request is for.
        let (_, page, _) = try await nativeFetch(URL(string: origin + "/")!)
        func setting(_ name: String) -> String? {
            let pattern = "\"\(name)\"\\s*:\\s*\"?([\\w.%-]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
                  let range = Range(match.range(at: 1), in: page) else { return nil }
            return String(page[range])
        }
        guard setting("LOGGED_IN") != "false" else { throw FeedError.notLoggedIn("YouTube session is logged out") }
        let version = setting("INNERTUBE_CLIENT_VERSION") ?? "2.20261101.00.00"
        let userSession = setting("USER_SESSION_ID")

        let cookies = await cookieStore.allCookies().filter { $0.domain.hasSuffix("youtube.com") }
        func cookie(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
        guard let sapisid = cookie("SAPISID") ?? cookie("__Secure-3PAPISID") else {
            throw FeedError.notLoggedIn("YouTube login required")
        }
        // YouTube signs API requests with a hash of the session, the time, the session's API
        // cookie, and the origin; one per cookie it has.
        let time = String(Int(Date().timeIntervalSince1970))
        func hash(_ scheme: String, _ value: String) -> String {
            let input = ([userSession].compactMap { $0 } + [time, value, origin]).joined(separator: " ")
            let digest = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(scheme) " + ([time, digest] + (userSession == nil ? [] : ["u"])).joined(separator: "_")
        }
        var authorization = [hash("SAPISIDHASH", sapisid)]
        if let value = cookie("__Secure-1PAPISID") { authorization.append(hash("SAPISID1PHASH", value)) }
        if let value = cookie("__Secure-3PAPISID") { authorization.append(hash("SAPISID3PHASH", value)) }

        let action = subscribed ? "subscribe" : "unsubscribe"
        var request = URLRequest(url: URL(string: "\(origin)/youtubei/v1/subscription/\(action)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "en"]],
            "channelIds": [channelId],
        ])
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { Self.cookie($0, matches: request.url!) }) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization.joined(separator: " "), forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(setting("SESSION_INDEX") ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let pageId = setting("DELEGATED_SESSION_ID") { request.setValue(pageId, forHTTPHeaderField: "X-Goog-PageId") }
        if let visitor = setting("VISITOR_DATA") { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Bootstrap-Logged-In")
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        #if DEBUG
        NSLog("Royal %@ %@ -> %d %@", action, channelId, status, body.replacingOccurrences(of: "\n", with: " "))
        #endif
        if status == 401 || status == 403 { throw FeedError.notLoggedIn("YouTube login required") }
        guard status == 200 else { throw FeedError.failed("YouTube couldn't \(action) (HTTP \(status))") }
        // A request YouTube didn't take as signed in still answers 200, just without saying the
        // channel's button changed.
        let confirmed = body.range(of: "\"subscribed\"\\s*:\\s*\(subscribed)", options: .regularExpression) != nil
        guard confirmed else {
            throw FeedError.failed("YouTube didn't confirm the change. Check you're logged in to YouTube in Settings.")
        }
    }

    struct Page {
        let posts: [FeedPost]
        // Where the next page starts, when the source has more.
        let next: Int?
    }

    // NSFW posts and subreddits are always fetched; their images stay blurred until tapped (PostRow).
    private static let showsNSFW = true

    // The followed subreddits, A to Z.
    func subreddits() async throws -> [String] {
        guard !sourcesScript.isEmpty else { throw FeedError.failed("sources.js missing from app bundle") }
        let result = try await run(sourcesScript + "return JSON.stringify(await Royal.fetchSubscribedSubreddits({ nsfw }));",
                                   ["nsfw": Self.showsNSFW])
        guard let json = result as? String else { throw FeedError.failed("No result from page") }
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    func posts(_ key: FeedKey, offset: Int = 0, limit: Int = 100) async throws -> Page {
        var arguments: [String: Any] = ["source": key.source.rawValue, "limit": limit,
                                        "offset": offset, "subreddit": "",
                                        "nsfw": Self.showsNSFW]
        switch key {
        case .reddit(let sort, let timeframe):
            arguments["sort"] = sort
            arguments["timeframe"] = timeframe
        case .subreddit(let name):
            arguments["sort"] = "top"
            arguments["timeframe"] = "day"
            arguments["subreddit"] = name
        case .rss:
            // Fetched natively; see FeedStore.fetchRSS.
            throw FeedError.failed("RSS feeds aren't fetched by sources.js")
        case .youtube:
            arguments["feed"] = "subscriptions"
        case .youtubeHome:
            arguments["feed"] = "home"
        }
        guard !sourcesScript.isEmpty else { throw FeedError.failed("sources.js missing from app bundle") }
        let result = try await run(sourcesScript + """
            const fetchers = {
              reddit: async () => ({ posts: await Royal.fetchReddit(limit, { sort, timeframe, subreddit, nsfw }), next: null }),
              youtube: async () => ({ posts: await Royal.fetchYouTube(limit, { feed }), next: null }),
            };
            try {
              return JSON.stringify(await fetchers[source]());
            } catch (e) {
              return JSON.stringify({ error: String(e.message ?? e), notLoggedIn: e instanceof Royal.NotLoggedInError });
            }
            """, arguments)

        struct Response: Decodable {
            let posts: [FeedPost]?
            let next: Int?
            let error: String?
            let notLoggedIn: Bool?
        }
        guard let json = result as? String else { throw FeedError.failed("No result from page") }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        if let error = response.error {
            throw response.notLoggedIn == true ? FeedError.notLoggedIn(error) : FeedError.failed(error)
        }
        return Page(posts: response.posts ?? [], next: response.next)
    }
}
