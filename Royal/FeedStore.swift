import SwiftUI

enum FeedKey: Hashable {
    case reddit(sort: String, timeframe: String)
    case hn(list: String)
    case youtube

    var source: FeedSource {
        switch self {
        case .reddit: .reddit
        case .hn: .hn
        case .youtube: .youtube
        }
    }

    // The combined page: Reddit Best, Hacker News top stories, YouTube subscriptions.
    static let combined: [FeedKey] = [.reddit(sort: "best", timeframe: "day"), .hn(list: "top"), .youtube]
}

struct FeedState {
    var posts: [FeedPost] = []
    var error: String?
    var loading = false
    var loaded = false
    // Offset of the next page, for sources that load in pages.
    var next: Int?
    var loadingMore = false
}

enum AppTab: Hashable {
    case hn, reddit, all, youtube, settings
}

// Holds every loaded feed so the combined page and single-source tabs share results.
@MainActor
final class FeedStore: ObservableObject {
    private let session = FeedSession()
    @Published private(set) var feeds: [FeedKey: FeedState] = [:]
    @Published private(set) var loggedIn: [FeedSource: Bool] = [:]
    @Published var selectedTab: AppTab = .all
    // The video in the docked player.
    @Published var playingVideo: FeedPost?
    // Newest first. Synced through iCloud; see SavedPostsStorage.
    @Published private(set) var saved = SavedPostsStorage.load()
    private var cloudObserver: NSObjectProtocol?

    init() {
        // Pick up posts saved or unsaved on another device.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.saved = SavedPostsStorage.load() }
        }
    }

    var savedPosts: [FeedPost] {
        saved.map(\.post)
    }

    func isSaved(_ post: FeedPost) -> Bool {
        saved.contains { $0.post.id == post.id }
    }

    func toggleSaved(_ post: FeedPost) {
        if let index = saved.firstIndex(where: { $0.post.id == post.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(SavedPost(post: post, savedAt: Date()), at: 0)
        }
        SavedPostsStorage.save(saved)
    }

    func state(_ key: FeedKey) -> FeedState {
        feeds[key] ?? FeedState()
    }

    func load(_ keys: [FeedKey], force: Bool = false) async {
        // Marks the feeds loading before the first suspension, so a caller that just
        // changed what's shown never draws a frame with the old state.
        let started = keys.filter { begin($0, force: force) }
        await withTaskGroup(of: Void.self) { group in
            for key in started {
                group.addTask { await self.fetch(key) }
            }
        }
        if !started.isEmpty && keys == FeedKey.combined { recordRefresh() }
    }

    // Marks the feed loading, or returns false to skip it.
    private func begin(_ key: FeedKey, force: Bool) -> Bool {
        var state = state(key)
        if state.loading || (state.loaded && !force) { return false }
        state.loading = true
        feeds[key] = state
        return true
    }

    private func fetch(_ key: FeedKey) async {
        let state = state(key)
        do {
            let page = try await session.posts(key)
            feeds[key] = FeedState(posts: page.posts, loaded: true, next: page.next)
        } catch {
            // Keep earlier posts visible when a refresh fails.
            feeds[key] = FeedState(posts: state.posts, error: error.localizedDescription, loaded: true)
        }
        loggedIn[key.source] = await session.isLoggedIn(key.source)
    }

    // After a login page closes: reloads `keys` if any of `sources` is now logged in.
    // The login status and the loading feeds change together, so the login card isn't
    // replaced by the feeds' old logged-out errors while they reload.
    func finishLogin(_ sources: [FeedSource], reloading keys: [FeedKey]) async {
        var status: [FeedSource: Bool] = [:]
        for source in FeedSource.allCases {
            status[source] = await session.isLoggedIn(source)
        }
        loggedIn = status
        if sources.contains(where: { status[$0] == true }) {
            await load(keys, force: true)
        }
    }

    // Fetches the next page of each feed that has more; called near the end of a list.
    func loadMore(_ keys: [FeedKey]) async {
        for key in keys {
            var state = state(key)
            guard let offset = state.next, !state.loading, !state.loadingMore else { continue }
            state.loadingMore = true
            feeds[key] = state
            do {
                let page = try await session.posts(key, offset: offset)
                state = self.state(key)
                // The story list can shift between pages; skip repeats.
                let known = Set(state.posts.map(\.id))
                state.posts += page.posts.filter { !known.contains($0.id) }
                state.next = page.next
                if keys == FeedKey.combined { rememberSeen(page.posts) }
            } catch {
                state = self.state(key)
            }
            state.loadingMore = false
            feeds[key] = state
        }
    }

    // MARK: New since last refresh (All feed)

    private static let seenKey = "allFeedSeenIDs"
    private static let refreshedKey = "allFeedRefreshedAt"
    private static let sourcesKey = "allFeedSources"
    private static let seenLimit = 3000

    // When the All feed was last refreshed; shown atop the feed.
    @Published private(set) var lastRefresh: Date?
    // When the All feed was refreshed before this one; the divider shows this time.
    @Published private(set) var previousRefresh: Date?
    // Post ids the All feed had shown as of that earlier refresh.
    private var previouslySeen: Set<String> = []
    // Sources that had posts in some earlier refresh. A source just logged into has
    // none, and its posts aren't called new, or they'd all sit above the divider.
    private var previousSources: Set<FeedSource> = []

    // Remembers what this refresh shows, so the next refresh can tell what's new.
    // Posts from feeds that failed this time stay remembered from earlier refreshes.
    private func recordRefresh() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: Self.seenKey) ?? []
        previouslySeen = Set(stored)
        previousRefresh = defaults.object(forKey: Self.refreshedKey) as? Date
        let storedSources = Set(defaults.stringArray(forKey: Self.sourcesKey) ?? [])
        previousSources = Set(storedSources.compactMap(FeedSource.init(rawValue:)))
        let currentPosts = posts(FeedKey.combined)
        defaults.set(Array(storedSources.union(currentPosts.map(\.source.rawValue))), forKey: Self.sourcesKey)
        let current = currentPosts.map(\.id)
        let currentSet = Set(current)
        let updated = stored.filter { !currentSet.contains($0) } + current
        defaults.set(Array(updated.suffix(Self.seenLimit)), forKey: Self.seenKey)
        let now = Date()
        defaults.set(now, forKey: Self.refreshedKey)
        lastRefresh = now
    }

    // Adds posts loaded after a refresh, so the next refresh doesn't call them new.
    private func rememberSeen(_ posts: [FeedPost]) {
        let defaults = UserDefaults.standard
        let ids = posts.map(\.id)
        let idSet = Set(ids)
        let stored = (defaults.stringArray(forKey: Self.seenKey) ?? []).filter { !idSet.contains($0) }
        defaults.set(Array((stored + ids).suffix(Self.seenLimit)), forKey: Self.seenKey)
    }

    // Splits the All feed into posts new since the previous refresh and those already seen.
    // Reddit and HN rank posts, so an older post can be new to the feed; YouTube is
    // chronological, so its videos are new only if posted after the previous refresh.
    // A source new to the feed has nothing new yet, so it mixes in with the rest.
    func splitByRefresh(_ posts: [FeedPost]) -> (new: [FeedPost], seen: [FeedPost])? {
        guard let previousRefresh, !previouslySeen.isEmpty else { return nil }
        let cutoff = previousRefresh.timeIntervalSince1970
        func isNew(_ post: FeedPost) -> Bool {
            if previouslySeen.contains(post.id) || !previousSources.contains(post.source) { return false }
            if post.source == .youtube, let publishedAt = post.publishedAt { return publishedAt > cutoff }
            return true
        }
        return (posts.filter(isNew), posts.filter { !isNew($0) })
    }

    // After logging in, retry feeds that failed.
    func reloadFailed() async {
        await refreshLoginStatus()
        await load(feeds.filter { $0.value.error != nil }.map(\.key), force: true)
    }

    func refreshLoginStatus() async {
        for source in FeedSource.allCases {
            loggedIn[source] = await session.isLoggedIn(source)
        }
    }

    func diagnostics() async -> String {
        await session.diagnostics()
    }

    // Alternates sources in key order; when one runs short the others fill the rest.
    // Links shared by several sources are kept once.
    func posts(_ keys: [FeedKey]) -> [FeedPost] {
        let lists = keys.map { state($0).posts }
        var out: [FeedPost] = []
        var seenUrls = Set<String>()
        var next = Array(repeating: 0, count: lists.count)
        var progressed = true
        while progressed {
            progressed = false
            for i in lists.indices {
                while next[i] < lists[i].count {
                    let post = lists[i][next[i]]
                    next[i] += 1
                    if seenUrls.insert(post.url).inserted {
                        out.append(post)
                        progressed = true
                        break
                    }
                }
            }
        }
        return out
    }
}
