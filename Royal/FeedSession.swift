import UIKit
import WebKit

enum FeedSource: String, Codable, CaseIterable, Identifiable {
    case reddit, hn, youtube

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reddit: "Reddit"
        case .hn: "Hacker News"
        case .youtube: "YouTube"
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
    let videoId: String?
    let published: String?
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
    private static let allowedHosts: Set<String> = ["www.reddit.com", "hacker-news.firebaseio.com", "www.youtube.com"]
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
            return { fetchReddit, fetchHackerNewsPage, fetchYouTube, NotLoggedInError };
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

    private func run(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await ensureLoaded()
        return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    func isLoggedIn(_ source: FeedSource) async -> Bool {
        let cookies = await cookieStore.allCookies()
        switch source {
        case .reddit: return cookies.contains { $0.name == "reddit_session" && $0.domain.hasSuffix("reddit.com") }
        case .youtube: return cookies.contains { $0.name == "LOGIN_INFO" && $0.domain.hasSuffix("youtube.com") }
        case .hn: return true
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

    // Hacker News loads a page at a time; each story is its own request, so a full
    // 100 up front is slow. Reddit and YouTube return everything in one request.
    static let hackerNewsPageSize = 30

    struct Page {
        let posts: [FeedPost]
        // Where the next page starts, when the source has more.
        let next: Int?
    }

    func posts(_ key: FeedKey, offset: Int = 0, limit: Int = 100) async throws -> Page {
        var arguments: [String: Any] = ["source": key.source.rawValue, "limit": limit,
                                        "offset": offset, "pageSize": Self.hackerNewsPageSize]
        switch key {
        case .reddit(let sort, let timeframe):
            arguments["sort"] = sort
            arguments["timeframe"] = timeframe
        case .hn(let list):
            arguments["list"] = list
        case .youtube:
            break
        }
        guard !sourcesScript.isEmpty else { throw FeedError.failed("sources.js missing from app bundle") }
        let result = try await run(sourcesScript + """
            const fetchers = {
              reddit: async () => ({ posts: await Royal.fetchReddit(limit, { sort, timeframe }), next: null }),
              hn: () => Royal.fetchHackerNewsPage(pageSize, { list, offset }),
              youtube: async () => ({ posts: await Royal.fetchYouTube(limit), next: null }),
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
