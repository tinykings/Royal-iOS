import SwiftUI

enum FeedKey: Hashable, Codable {
    case reddit(sort: String, timeframe: String)
    // One followed subreddit's Top today, chosen on the Reddit tab.
    case subreddit(name: String)
    case hn(list: String)
    case youtube
    // The recommendations on YouTube's Home page, chosen on the YouTube tab.
    case youtubeHome

    var source: FeedSource {
        switch self {
        case .reddit, .subreddit: .reddit
        case .hn: .hn
        case .youtube, .youtubeHome: .youtube
        }
    }

    // The combined page: Reddit's top posts today, Hacker News top stories, YouTube subscriptions.
    static let combined: [FeedKey] = [.reddit(sort: "top", timeframe: "day"), .hn(list: "top"), .youtube]
}

struct FeedState {
    var posts: [FeedPost] = []
    var error: String?
    var loading = false
    var loaded = false
    // Offset of the next page, for sources that load in pages.
    var next: Int?
    var loadingMore = false
    // Why the last next-page fetch failed; paging waits for a retry instead of trying again
    // every time a row near the end appears.
    var moreError: String?
    var loadedAt: Date?
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
    @Published private(set) var loginCookies: [FeedSource: [LoginCookie]] = [:]
    // The followed subreddits, for the Reddit tab's menu.
    @Published private(set) var subreddits: [String] = []
    @Published var selectedTab: AppTab = .all
    // The video in the docked player.
    @Published var playingVideo: FeedPost?
    // Bumped when the showing tab's icon is tapped again; that tab scrolls to the top.
    @Published private(set) var reselected: (tab: AppTab, count: Int)?
    // Newest first. Synced through CloudKit (SavedSync); kept on this device alone
    // (SavedPostsStorage) until sync has turned on for an Apple Account.
    @Published private(set) var saved = SavedPostsStorage.load()
    let savedSync: SavedSync

    init() {
        savedSync = SavedSync()
        savedSync.onChange = { [weak self] in
            self?.reloadSaved()
            self?.mergeSyncedSeen()
        }
        savedSync.localSeen = {
            let defaults = UserDefaults.standard
            return (defaults.stringArray(forKey: FeedStore.seenKey) ?? [], defaults.stringArray(forKey: FeedStore.sourcesKey) ?? [])
        }
        if savedSync.isActive {
            // Left by a build that synced through key-value storage too.
            savedSync.importLocal(SavedPostsStorage.load())
            SavedPostsStorage.save([])
            reloadSaved()
            // Posts shown while sync was paused, or before seen synced at all.
            sendSeen()
        }
        savedSync.scheduleSync(after: 0)
        restoreCache()
    }

    // Shows the synced library while sync is active, otherwise this device's own list.
    private func reloadSaved() {
        let list = savedSync.isActive ? savedSync.library.savedPosts : SavedPostsStorage.load()
        func fingerprint(_ items: [SavedPost]) -> [String] {
            items.map { "\($0.post.id) \($0.savedAt.timeIntervalSince1970)" }
        }
        guard fingerprint(list) != fingerprint(saved) else { return }
        saved = list
    }

    func reselect(_ tab: AppTab) {
        reselected = (tab, (reselected?.count ?? 0) + 1)
    }

    var savedPosts: [FeedPost] {
        saved.map(\.post)
    }

    func isSaved(_ post: FeedPost) -> Bool {
        saved.contains { $0.post.id == post.id }
    }

    func toggleSaved(_ post: FeedPost) {
        if savedSync.isActive {
            savedSync.setSaved(post, !isSaved(post))
            return
        }
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

    // Fetches in progress. They run apart from the caller's task, so a refresh finishes
    // even if SwiftUI cancels the pull-to-refresh task, and a refresh that finds a feed
    // already loading waits for that fetch instead of returning before it lands.
    private var fetches: [FeedKey: Task<Void, Never>] = [:]

    // Fetches every loaded Reddit feed again after the NSFW setting changes. Turning it off
    // hides NSFW posts at once (see FeedListView); this fills the room they took up.
    func reloadRedditForNSFWChange() async {
        let keys = feeds.filter { $0.key.source == .reddit && $0.value.loaded }.map(\.key)
        if keys.isEmpty { await loadSubreddits() }
        await load(keys, force: true)
    }

    // A failure keeps the list already shown; the next refresh tries again.
    func loadSubreddits() async {
        if let names = try? await session.subreddits() { subreddits = names }
    }

    func load(_ keys: [FeedKey], force: Bool = false) async {
        if force && keys.contains(where: { $0.source == .reddit }) {
            Task { await loadSubreddits() }
        }
        // Marks the feeds loading before the first suspension, so a caller that just
        // changed what's shown never draws a frame with the old state.
        var started: [FeedKey] = []
        var waiting: [Task<Void, Never>] = []
        for key in keys {
            if let running = fetches[key] {
                waiting.append(running)
                continue
            }
            var state = state(key)
            if state.loaded && !force { continue }
            state.loading = true
            feeds[key] = state
            let task = Task {
                await self.fetch(key)
                self.fetches[key] = nil
            }
            fetches[key] = task
            started.append(key)
            waiting.append(task)
        }
        let refreshingAll = !started.isEmpty && keys == FeedKey.combined
        // Catch up on what other devices have shown while the feeds load, so it isn't new here.
        if refreshingAll { savedSync.scheduleSync(after: 0) }
        for task in waiting { await task.value }
        if refreshingAll {
            await savedSync.waitUntilIdle(timeout: 4)
            recordRefresh()
        }
        if !started.isEmpty { saveCache() }
    }

    private func fetch(_ key: FeedKey) async {
        let state = state(key)
        do {
            let page = try await session.posts(key)
            var posts = page.posts
            // YouTube's Home mostly reshuffles below its first videos, which is all that fits on
            // screen, so videos the last fetch didn't have go first. This only orders this feed;
            // the All feed's new posts are tracked apart and never include recommendations.
            if key == .youtubeHome {
                let known = Set(state.posts.map(\.id))
                posts = posts.filter { !known.contains($0.id) } + posts.filter { known.contains($0.id) }
            }
            feeds[key] = FeedState(posts: posts, loaded: true, next: page.next, loadedAt: Date())
        } catch {
            // Keep earlier posts visible when a refresh fails.
            feeds[key] = FeedState(posts: state.posts, error: error.localizedDescription, loaded: true, loadedAt: state.loadedAt)
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
    // After a failure it waits for `retry`, which the list's retry button passes.
    func loadMore(_ keys: [FeedKey], retry: Bool = false) async {
        for key in keys {
            var state = state(key)
            guard let offset = state.next, !state.loading, !state.loadingMore,
                  retry || state.moreError == nil else { continue }
            let loadedAt = state.loadedAt
            state.loadingMore = true
            state.moreError = nil
            feeds[key] = state
            do {
                let page = try await session.posts(key, offset: offset)
                state = self.state(key)
                // A refresh replaced the feed while this page loaded; it no longer follows on.
                guard state.loadedAt == loadedAt else { continue }
                // The story list can shift between pages; skip repeats.
                let known = Set(state.posts.map(\.id))
                state.posts += page.posts.filter { !known.contains($0.id) }
                state.next = page.next
                if FeedKey.combined.contains(key) {
                    pagedSinceRefresh.formUnion(page.posts.map(\.id))
                    rememberSeen(page.posts)
                }
            } catch {
                state = self.state(key)
                guard state.loadedAt == loadedAt else { continue }
                state.moreError = error.localizedDescription
            }
            state.loadingMore = false
            feeds[key] = state
        }
        saveCache()
    }

    // MARK: Kept between launches

    // Feeds only reload when asked, by pulling down or tapping the tab again. Opening the
    // app shows the posts it had when last closed, so posts not yet looked at stay new
    // rather than joining the earlier ones under a refresh nobody asked for.
    private struct Cache: Codable {
        struct Feed: Codable {
            let key: FeedKey
            let posts: [FeedPost]
            let next: Int?
            let loadedAt: Date?
        }
        let feeds: [Feed]
        let lastRefresh: Date?
        let previousRefresh: Date?
        let previouslySeen: Set<String>
        let previousSources: Set<FeedSource>
        let pagedSinceRefresh: Set<String>
    }

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "feeds.json")

    private func saveCache() {
        let cache = Cache(
            // A subreddit's posts and YouTube's recommendations are only kept while the app runs;
            // they're picked now and then, and would otherwise open however long ago they were
            // last looked at.
            feeds: feeds.compactMap { key, state in
                if case .subreddit = key { return nil }
                if case .youtubeHome = key { return nil }
                return state.posts.isEmpty ? nil
                    : Cache.Feed(key: key, posts: state.posts, next: state.next, loadedAt: state.loadedAt)
            },
            lastRefresh: lastRefresh, previousRefresh: previousRefresh, previouslySeen: previouslySeen,
            previousSources: previousSources, pagedSinceRefresh: pagedSinceRefresh)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func restoreCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        for feed in cache.feeds {
            // Apply the Hacker News cap to feeds cached before the limit existed too.
            let isHackerNews = feed.key.source == .hn
            let posts = isHackerNews ? Array(feed.posts.prefix(100)) : feed.posts
            let next = isHackerNews && (feed.next ?? 100) >= 100 ? nil : feed.next
            feeds[feed.key] = FeedState(posts: posts, loaded: true, next: next, loadedAt: feed.loadedAt)
        }
        lastRefresh = cache.lastRefresh
        previousRefresh = cache.previousRefresh
        previouslySeen = cache.previouslySeen
        previousSources = cache.previousSources
        pagedSinceRefresh = cache.pagedSinceRefresh
    }

    // MARK: Accounts

    // Clears the source's login and drops its loaded posts.
    func logOut(_ source: FeedSource) async {
        await session.logOut(source)
        for key in feeds.keys where key.source == source {
            feeds[key] = FeedState()
        }
        if source == .reddit { subreddits = [] }
        loggedIn[source] = false
        loginCookies[source] = []
        saveCache()
    }

    // MARK: New since last refresh (All feed)

    private static let seenKey = "allFeedSeenIDs"
    private static let refreshedKey = "allFeedRefreshedAt"
    private static let sourcesKey = "allFeedSources"
    private static let seenLimit = 3000
    private static let markedReadKey = "allFeedMarkedRead"

    // Whether the All feed has ever been marked read on this install.
    @Published private(set) var hasMarkedRead = UserDefaults.standard.bool(forKey: FeedStore.markedReadKey)
    // When the All feed was last refreshed; shown atop the feed.
    @Published private(set) var lastRefresh: Date?
    // When the All feed was refreshed before this one; the divider shows this time.
    @Published private(set) var previousRefresh: Date?
    // Post ids the All feed had shown as of that earlier refresh.
    private var previouslySeen: Set<String> = []
    // Sources that had posts in some earlier refresh. A source just logged into has
    // none, and its posts aren't called new, or they'd all sit above the divider.
    private var previousSources: Set<FeedSource> = []
    // Posts that arrived by scrolling to the end since the latest refresh. They stay with
    // the seen posts at the bottom rather than jumping up above the divider.
    private var pagedSinceRefresh: Set<String> = []

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
        pagedSinceRefresh = []
        sendSeen()
    }

    // Offers this device's seen ids to sync with the desktop, when it's on.
    private func sendSeen() {
        guard savedSync.isActive, let local = savedSync.localSeen?() else { return }
        savedSync.noteSeen(ids: local.ids, sources: local.sources)
    }

    // Takes in what other devices' All feeds have shown. It counts from the next refresh,
    // like everything seen here; the posts on screen stay where they are.
    private func mergeSyncedSeen() {
        guard savedSync.isActive else { return }
        let library = savedSync.library
        guard !library.seen.isEmpty || !library.seenSources.isEmpty else { return }
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: Self.seenKey) ?? []
        let merged = SeenSyncCodec.merge(remote: library.seen, local: stored)
        if merged != stored { defaults.set(merged, forKey: Self.seenKey) }
        let storedSources = defaults.stringArray(forKey: Self.sourcesKey) ?? []
        let mergedSources = SeenSyncCodec.union(storedSources, library.seenSources)
        if mergedSources != storedSources { defaults.set(mergedSources, forKey: Self.sourcesKey) }
    }

    // Adds posts loaded after a refresh, so the next refresh doesn't call them new.
    private func rememberSeen(_ posts: [FeedPost]) {
        let defaults = UserDefaults.standard
        let ids = posts.map(\.id)
        let idSet = Set(ids)
        let stored = (defaults.stringArray(forKey: Self.seenKey) ?? []).filter { !idSet.contains($0) }
        defaults.set(Array((stored + ids).suffix(Self.seenLimit)), forKey: Self.seenKey)
        sendSeen()
    }

    // Marks everything the All feed shows as read, so it moves in with the earlier posts.
    // The next refresh brings only what's arrived since.
    func markAllRead() {
        let current = posts(FeedKey.combined)
        previouslySeen.formUnion(current.map(\.id))
        rememberSeen(current)
        // Published, so the feed redraws; the earlier posts now run up to the latest refresh.
        previousRefresh = lastRefresh ?? Date()
        hasMarkedRead = true
        UserDefaults.standard.set(true, forKey: Self.markedReadKey)
        saveCache()
    }

    // Splits the All feed into posts new since the previous refresh and those already seen.
    // Reddit and HN rank posts, so an older post can be new to the feed. YouTube is
    // chronological, so its new videos are the ones above the newest video already seen.
    // YouTube can add a video to the feed a while after it went up, so its age alone
    // can't say whether it arrived since the previous refresh; that's the fallback only
    // when none of the videos were seen before.
    // A source new to the feed has nothing new yet, so it mixes in with the rest.
    // Before anything's been seen, the whole feed is new.
    func splitByRefresh(_ posts: [FeedPost]) -> (new: [FeedPost], seen: [FeedPost]) {
        guard let previousRefresh, !previouslySeen.isEmpty else { return (posts, []) }
        let cutoff = previousRefresh.timeIntervalSince1970
        let videos = state(.youtube).posts
        let newestSeenVideo = videos.firstIndex { previouslySeen.contains($0.id) }
        let videosAboveSeen = Set(videos.prefix(newestSeenVideo ?? 0).map(\.id))
        func isNew(_ post: FeedPost) -> Bool {
            if previouslySeen.contains(post.id) || pagedSinceRefresh.contains(post.id)
                || !previousSources.contains(post.source) { return false }
            if post.source == .youtube {
                if newestSeenVideo != nil { return videosAboveSeen.contains(post.id) }
                if let publishedAt = post.publishedAt { return publishedAt > cutoff }
            }
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
            loginCookies[source] = await session.loginCookies(source)
        }
    }

    func diagnostics() async -> String {
        await session.diagnostics()
    }

    // Alternates sources in key order; when one runs short the others fill the rest.
    // A source with more pages to load ends the list where its posts run out, so its next
    // page continues the list below what's shown instead of slotting in among rows above.
    // Links shared by several sources are kept once.
    func posts(_ keys: [FeedKey]) -> [FeedPost] {
        let lists = keys.map { state($0).posts }
        let hasMore = keys.map { state($0).next != nil }
        var out: [FeedPost] = []
        var seenUrls = Set<String>()
        var next = Array(repeating: 0, count: lists.count)
        var progressed = true
        while progressed {
            progressed = false
            for i in lists.indices {
                var added = false
                while next[i] < lists[i].count {
                    let post = lists[i][next[i]]
                    next[i] += 1
                    if seenUrls.insert(post.url).inserted {
                        out.append(post)
                        added = true
                        break
                    }
                }
                if added {
                    progressed = true
                } else if hasMore[i] && keys.count > 1 {
                    return out
                }
            }
        }
        return out
    }
}
