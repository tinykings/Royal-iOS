import SwiftUI

enum FeedKey: Hashable, Codable {
    case reddit(sort: String, timeframe: String)
    // One followed subreddit's Top today, chosen on the Reddit tab.
    case subreddit(name: String)
    // Every RSS feed in Settings, newest first.
    case rss
    case youtube
    // The recommendations on YouTube's Home page, chosen on the YouTube tab.
    case youtubeHome

    var source: FeedSource {
        switch self {
        case .reddit, .subreddit: .reddit
        case .rss: .rss
        case .youtube, .youtubeHome: .youtube
        }
    }

    // The combined page: Reddit's top posts today, the RSS feeds, YouTube subscriptions.
    // FeedStore.combinedKeys leaves out the sources turned off in Settings.
    static let combined: [FeedKey] = [.reddit(sort: "top", timeframe: "day"), .rss, .youtube]
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
    // Says the feed waits for a pull to refresh, as after logging in or changing the RSS feeds.
    var notice: String?
}

enum AppTab: Hashable {
    case rss, reddit, all, youtube, settings
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
    // Sources turned off in Settings: their tabs show a dot and the All feed leaves them out.
    // A new install starts with RSS off, offered on the All feed beside the logins;
    // an install from before sources could be turned off keeps them all on.
    @Published private(set) var disabledSources: Set<FeedSource> = {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: Preference.disabledSources) else {
            return defaults.object(forKey: FeedStore.seenKey) == nil ? [.rss] : []
        }
        return Set(stored.split(separator: ",").compactMap { FeedSource(stored: String($0)) })
    }()
    // Whether sources have been turned on or off yet. Until then the All feed offers
    // to turn on the sources that start off.
    @Published private(set) var sourcesChosen = UserDefaults.standard.string(forKey: Preference.disabledSources) != nil

    // The All feed's feeds, without the sources turned off.
    var combinedKeys: [FeedKey] {
        FeedKey.combined.filter { !disabledSources.contains($0.source) }
    }

    func isEnabled(_ source: FeedSource) -> Bool {
        !disabledSources.contains(source)
    }

    // Turns a source on or off. With every source off, the All feed points to Settings.
    func setEnabled(_ source: FeedSource, _ enabled: Bool) {
        if enabled { disabledSources.remove(source) } else { disabledSources.insert(source) }
        sourcesChosen = true
        let disabled = disabledSources
        UserDefaults.standard.set(FeedSource.allCases.filter(disabled.contains).map(\.rawValue).joined(separator: ","),
                                  forKey: Preference.disabledSources)
    }

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
        // Installs from before RSS feeds were tracked have taken in every feed they list.
        if UserDefaults.standard.object(forKey: Self.rssFeedsKey) == nil && UserDefaults.standard.object(forKey: Self.seenKey) != nil {
            UserDefaults.standard.set(rssFeeds.map(\.url), forKey: Self.rssFeedsKey)
        }
        observeRSSBackup()
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

    // Whether the saved copy of the post came from the YouTube account's Watch Later playlist.
    func isFromWatchLater(_ post: FeedPost) -> Bool {
        post.source == .youtube && saved.first { $0.post.id == post.id }?.post.watchLater == true
    }

    func toggleSaved(_ post: FeedPost) {
        let saving = !isSaved(post)
        // Unsaving a video imported from Watch Later takes it out of the playlist too. Saving
        // in the app never puts anything in the playlist.
        if let videoId = post.videoId {
            if saving {
                setWatchLaterRemoval(videoId, pending: false)
            } else if isFromWatchLater(post) {
                setWatchLaterRemoval(videoId, pending: true)
                Task { await removeFromWatchLater(videoId) }
            }
        }
        if savedSync.isActive {
            savedSync.setSaved(post, saving)
            return
        }
        if let index = saved.firstIndex(where: { $0.post.id == post.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(SavedPost(post: post, savedAt: Date()), at: 0)
        }
        SavedPostsStorage.save(saved)
    }

    // MARK: Watch Later

    // Settings imports the videos in the YouTube account's Watch Later playlist into Saved,
    // marked as from there. It only goes one way: unsaving one takes it out of the playlist,
    // but saving a video in the app leaves the playlist alone. A video taken out of the
    // playlist on YouTube stays saved.
    //
    // A video unsaved here waits to come out of the playlist until YouTube confirms it,
    // and isn't imported again meanwhile. With sync on, its tombstone keeps the Watch
    // Later mark until then, so other devices (and Royal Saved on the web) leave it out
    // too, and whichever device next finds it still in the playlist takes it out.

    private static let watchLaterRemovalsKey = "watchLaterRemovals"
    private static let watchLaterInterval: TimeInterval = 60
    private var watchLaterChecked: Date?
    private var checkingWatchLater = false
    // When each video was last taken out of the playlist, so a list fetched before that
    // doesn't bring it straight back.
    private var watchLaterRemovedAt: [String: Date] = [:]

    // Videos to take out of Watch Later: unsaved on this device, or, with sync on, anywhere.
    private var watchLaterRemovals: Set<String> {
        let local = Set(UserDefaults.standard.stringArray(forKey: Self.watchLaterRemovalsKey) ?? [])
        return savedSync.isActive ? local.union(savedSync.library.watchLaterRemovals) : local
    }

    private func setWatchLaterRemoval(_ videoId: String, pending: Bool) {
        var local = Set(UserDefaults.standard.stringArray(forKey: Self.watchLaterRemovalsKey) ?? [])
        guard local.contains(videoId) != pending else { return }
        if pending { local.insert(videoId) } else { local.remove(videoId) }
        UserDefaults.standard.set(local.sorted(), forKey: Self.watchLaterRemovalsKey)
    }

    // The video's gone from the playlist; nothing's left to do for it.
    private func finishWatchLaterRemoval(_ videoId: String) {
        watchLaterRemovedAt[videoId] = Date()
        setWatchLaterRemoval(videoId, pending: false)
        savedSync.clearWatchLater(postID: "yt_\(videoId)")
    }

    // Returns whether the video's out of the playlist; a failure is retried at the next check.
    @discardableResult
    private func removeFromWatchLater(_ videoId: String) async -> Bool {
        do {
            try await session.removeFromWatchLater(videoId: videoId)
            finishWatchLaterRemoval(videoId)
            return true
        } catch {
            #if DEBUG
            NSLog("Royal Watch Later removal of %@ failed: %@", videoId, error.localizedDescription)
            #endif
            return false
        }
    }

    // Takes videos unsaved here, or with sync on anywhere, out of the playlist when an
    // earlier try didn't. Does nothing with none waiting; otherwise runs at most once a
    // minute unless forced, and only with YouTube on and logged in. Never imports.
    func retryWatchLaterRemovals(force: Bool = false) async {
        guard isEnabled(.youtube), !checkingWatchLater, !watchLaterRemovals.isEmpty else { return }
        if !force, let checked = watchLaterChecked, Date().timeIntervalSince(checked) < Self.watchLaterInterval { return }
        guard await session.isLoggedIn(.youtube) else { return }
        _ = try? await checkWatchLater(importing: false)
    }

    // Saves every video in the playlist that isn't saved yet, from Settings; returns how
    // many. Royal never imports on its own, since a playlist nobody clears out can hold
    // years of videos already watched.
    func importWatchLater() async throws -> Int {
        guard !checkingWatchLater else { throw FeedError.failed("Already checking Watch Later.") }
        guard await session.isLoggedIn(.youtube) else { throw FeedError.failed("Log in to YouTube first.") }
        return try await checkWatchLater(importing: true)
    }

    // Reads the playlist, takes out the videos waiting to come out, and, when importing,
    // saves the rest that aren't saved yet. Returns how many were saved.
    private func checkWatchLater(importing: Bool) async throws -> Int {
        checkingWatchLater = true
        defer { checkingWatchLater = false }
        let started = Date()
        watchLaterChecked = started
        // Let saves from other devices arrive first, so a video unsaved there isn't imported again.
        if savedSync.isActive {
            savedSync.scheduleSync(after: 0)
            try? await Task.sleep(for: .milliseconds(100))
            await savedSync.waitUntilIdle(timeout: 4)
        }
        let (videos, complete) = try await session.watchLater()
        let inPlaylist = Set(videos.compactMap(\.videoId))
        let removals = watchLaterRemovals
        for videoId in removals.sorted() {
            if inPlaylist.contains(videoId) {
                await removeFromWatchLater(videoId)
            } else if complete {
                // Taken out already, here or on YouTube.
                finishWatchLaterRemoval(videoId)
            }
        }
        guard importing else { return 0 }
        // The playlist's first video lands at the top of Saved, the rest in its order below.
        // Left out: videos waiting to come out of the playlist, including any unsaved while
        // this ran, and those taken out since the list was fetched.
        let skipped = removals.union(watchLaterRemovals)
        let now = Date()
        var imported: [SavedPost] = []
        for video in videos {
            guard let videoId = video.videoId, !skipped.contains(videoId), !isSaved(video),
                  (watchLaterRemovedAt[videoId] ?? .distantPast) < started else { continue }
            var post = video
            post.watchLater = true
            imported.append(SavedPost(post: post, savedAt: now.addingTimeInterval(-0.001 * Double(imported.count))))
        }
        guard !imported.isEmpty else { return 0 }
        if savedSync.isActive {
            for item in imported { savedSync.setSaved(item.post, true, at: item.savedAt) }
        } else {
            saved = (saved + imported).sorted { $0.savedAt > $1.savedAt }
            SavedPostsStorage.save(saved)
        }
        return imported.count
    }

    // Channels subscribed to or unsubscribed from in the app while it runs, over what the
    // subscriptions feed shows.
    @Published private var subscriptionChanges: [String: Bool] = [:]
    // Channels with a subscribe request on the way.
    @Published private(set) var subscribing: Set<String> = []
    // Why the last subscribe or unsubscribe failed, until it's dismissed.
    @Published var subscribeError: String?

    // Whether the account follows the video's channel, as far as the app knows: changed here,
    // or with a video in the subscriptions feed.
    func isSubscribed(_ post: FeedPost) -> Bool {
        guard let channel = post.channelId else { return false }
        return subscriptionChanges[channel] ?? state(.youtube).posts.contains { $0.channelId == channel }
    }

    func toggleSubscribed(_ post: FeedPost) async {
        guard let channel = post.channelId, !subscribing.contains(channel) else { return }
        let subscribe = !isSubscribed(post)
        subscribing.insert(channel)
        defer { subscribing.remove(channel) }
        do {
            try await session.setSubscribed(channelId: channel, subscribe)
            subscriptionChanges[channel] = subscribe
        } catch {
            subscribeError = error.localizedDescription
        }
    }

    func state(_ key: FeedKey) -> FeedState {
        feeds[key] ?? FeedState()
    }

    // Fetches in progress. They run apart from the caller's task, so a refresh finishes
    // even if SwiftUI cancels the pull-to-refresh task, and a refresh that finds a feed
    // already loading waits for that fetch instead of returning before it lands.
    private var fetches: [FeedKey: Task<Void, Never>] = [:]

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
        let refreshingAll = !started.isEmpty && keys == combinedKeys
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
            let page = key == .rss ? try await fetchRSS() : try await session.posts(key)
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
        if key == .youtube { Task { await retryWatchLaterRemovals() } }
    }

    // Fetches the next page of each feed that has more; called near the end of a list.
    // After a failure it waits for `retry`, which the list's retry button passes.
    func loadMore(_ keys: [FeedKey], retry: Bool = false) async {
        let shownBefore = Set(posts(combinedKeys).map(\.id))
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
            } catch {
                state = self.state(key)
                guard state.loadedAt == loadedAt else { continue }
                state.moreError = error.localizedDescription
            }
            state.loadingMore = false
            feeds[key] = state
        }
        // A page ends the All feed further down, which also brings in more of the other
        // sources' posts; they all stay at the bottom with the seen posts.
        let revealed = posts(combinedKeys).filter { !shownBefore.contains($0.id) }
        if !revealed.isEmpty {
            pagedSinceRefresh.formUnion(revealed.map(\.id))
            rememberSeen(revealed)
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
        let previousVideos: Set<String>

        init(feeds: [Feed], lastRefresh: Date?, previousRefresh: Date?, previouslySeen: Set<String>,
             previousSources: Set<FeedSource>, pagedSinceRefresh: Set<String>, previousVideos: Set<String>) {
            self.feeds = feeds
            self.lastRefresh = lastRefresh
            self.previousRefresh = previousRefresh
            self.previouslySeen = previouslySeen
            self.previousSources = previousSources
            self.pagedSinceRefresh = pagedSinceRefresh
            self.previousVideos = previousVideos
        }

        // A feed this build no longer has, like Hacker News before RSS, is dropped
        // rather than losing the rest of the cache.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            feeds = try container.decode([Lossy<Feed>].self, forKey: .feeds).compactMap(\.value)
            lastRefresh = try container.decodeIfPresent(Date.self, forKey: .lastRefresh)
            previousRefresh = try container.decodeIfPresent(Date.self, forKey: .previousRefresh)
            previouslySeen = try container.decode(Set<String>.self, forKey: .previouslySeen)
            previousSources = try container.decode(Set<FeedSource>.self, forKey: .previousSources)
            pagedSinceRefresh = try container.decode(Set<String>.self, forKey: .pagedSinceRefresh)
            // Caches saved before it existed don't have it.
            previousVideos = try container.decodeIfPresent(Set<String>.self, forKey: .previousVideos) ?? []
        }

        private struct Lossy<Value: Decodable>: Decodable {
            let value: Value?
            init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
        }
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
            previousSources: previousSources, pagedSinceRefresh: pagedSinceRefresh,
            previousVideos: previousVideos)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func restoreCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        for feed in cache.feeds {
            feeds[feed.key] = FeedState(posts: feed.posts, loaded: true, next: feed.next, loadedAt: feed.loadedAt)
        }
        lastRefresh = cache.lastRefresh
        previousRefresh = cache.previousRefresh
        previouslySeen = cache.previouslySeen
        previousSources = cache.previousSources
        pagedSinceRefresh = cache.pagedSinceRefresh
        previousVideos = cache.previousVideos
    }

    // MARK: RSS

    // The feeds the RSS tab shows, in the order added.
    @Published private(set) var rssFeeds = RSSFeed.load()
    // Why each feed failed in the last fetch, by address, for the feed list in Settings.
    @Published private(set) var rssFeedErrors: [String: String] = [:]

    // Looks up the feeds at a pasted address: the feed itself, or a website's feeds.
    func findRSSFeeds(_ text: String) async throws -> [RSSFetcher.Found] {
        guard let url = RSSFeed.address(text) else { throw FeedError.failed("That isn't a web address.") }
        do {
            return try await RSSFetcher.discover(url)
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.failed("Couldn't look up \(url.host ?? "that address"): \(error.localizedDescription)")
        }
    }

    // Adds a feed found by looking up an address, then reloads the tab.
    func addRSSFeed(_ found: RSSFetcher.Found) {
        guard !rssFeeds.contains(where: { $0.url == found.url }) else { return }
        rssFeeds.append(RSSFeed(url: found.url, title: found.title))
        saveRSSFeeds()
    }

    func removeRSSFeeds(at offsets: IndexSet) {
        let removed = Set(offsets.map { rssFeeds[$0].url })
        rssFeeds.remove(atOffsets: offsets)
        for url in removed { rssFeedErrors[url] = nil }
        // Added again later, it starts over with only its latest items new.
        let defaults = UserDefaults.standard
        let taken = (defaults.stringArray(forKey: Self.rssFeedsKey) ?? []).filter { !removed.contains($0) }
        defaults.set(taken, forKey: Self.rssFeedsKey)
        saveRSSFeeds()
    }

    func moveRSSFeeds(from offsets: IndexSet, to destination: Int) {
        rssFeeds.move(fromOffsets: offsets, toOffset: destination)
        RSSFeed.save(rssFeeds)
    }

    // Adds an OPML file's feeds that aren't in the list yet; returns how many.
    @discardableResult
    func importRSSFeeds(_ feeds: [RSSFeed]) -> Int {
        var known = Set(rssFeeds.map(\.url))
        let added = feeds.filter { known.insert($0.url).inserted }
        guard !added.isEmpty else { return 0 }
        rssFeeds += added
        saveRSSFeeds()
        return added.count
    }

    private func saveRSSFeeds() {
        RSSFeed.save(rssFeeds)
        noteRSSChanged()
    }

    // Feeds only load on a pull to refresh, so a changed feed list waits for one.
    private func noteRSSChanged() {
        guard isEnabled(.rss) else { return }
        var state = state(.rss)
        state.notice = "Pull down to update your feeds."
        feeds[.rss] = state
    }

    // Follows the feed list's iCloud backup (RSSFeed.save): picks it up when it
    // arrives on a new install or changes on another device, and backs this list
    // up when it's the newer one.
    private func observeRSSBackup() {
        RSSFeed.migrateLocal()
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard keys.contains(RSSFeed.cloudKey) else { return }
            MainActor.assumeIsolated { self?.reconcileRSSFeeds() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        reconcileRSSFeeds()
    }

    // The newer of this device's list and the iCloud copy wins.
    private func reconcileRSSFeeds() {
        let localModified = RSSFeed.localModified
        guard let backup = RSSFeed.loadFromCloud() else {
            if localModified > 0 { RSSFeed.saveToCloud(RSSFeed.Backup(feeds: rssFeeds, modified: localModified)) }
            return
        }
        if backup.modified > localModified {
            RSSFeed.adopt(backup)
            guard backup.feeds != rssFeeds else { return }
            let kept = Set(backup.feeds.map(\.url))
            rssFeedErrors = rssFeedErrors.filter { kept.contains($0.key) }
            rssFeeds = backup.feeds
            noteRSSChanged()
        } else if localModified > backup.modified {
            RSSFeed.saveToCloud(RSSFeed.Backup(feeds: rssFeeds, modified: localModified))
        }
    }

    // Every feed at once, newest items first. A feed that fails leaves the rest showing,
    // and its error shows in the feed list; it's an error for the tab only when all fail.
    private func fetchRSS() async throws -> FeedSession.Page {
        let list = rssFeeds
        // One task per feed, all running at once, awaited in turn. Not a task group: on iOS 27
        // a group's finishing child crashed Royal at launch (in swift::TaskGroup::offer).
        let tasks = list.map { feed in
            (feed.url, Task.detached { () -> Result<RSSFetcher.Result, Error> in
                guard let url = URL(string: feed.url) else { return .failure(FeedError.failed("Not a web address")) }
                do { return .success(try await RSSFetcher.fetch(url)) } catch { return .failure(error) }
            })
        }
        var results: [String: Result<RSSFetcher.Result, Error>] = [:]
        for (url, task) in tasks { results[url] = await task.value }
        var errors: [String: String] = [:]
        var posts: [FeedPost] = []
        var titled = false
        // A feed new to the All feed brings in only its latest few items as new; the rest
        // join the earlier posts.
        let defaults = UserDefaults.standard
        var taken = defaults.stringArray(forKey: Self.rssFeedsKey) ?? []
        var olderItems: [FeedPost] = []
        for (index, feed) in rssFeeds.enumerated() {
            switch results[feed.url] {
            case .success(let result)?:
                posts += result.posts
                if !taken.contains(feed.url) && !result.posts.isEmpty {
                    taken.append(feed.url)
                    let newest = result.posts.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
                    olderItems += newest.dropFirst(Self.rssFirstLookCount)
                }
                if let title = result.title, !title.isEmpty, title != feed.title {
                    rssFeeds[index].title = title
                    titled = true
                }
            case .failure(let error)?:
                errors[feed.url] = error.localizedDescription
            case nil:
                break
            }
        }
        if titled { RSSFeed.save(rssFeeds, changed: false) }
        rssFeedErrors = errors
        if !list.isEmpty, errors.count == results.count, let first = errors.values.first {
            throw FeedError.failed(list.count == 1 ? first : "None of your feeds loaded (\(first)).")
        }
        defaults.set(taken, forKey: Self.rssFeedsKey)
        if !olderItems.isEmpty {
            previouslySeen.formUnion(olderItems.map(\.id))
            rememberSeen(olderItems)
        }
        var seenIDs = Set<String>()
        let newest = posts.filter { seenIDs.insert($0.id).inserted }
            .sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        return FeedSession.Page(posts: Array(newest.prefix(100)), next: nil)
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
    // RSS feeds whose items the All feed has taken in.
    private static let rssFeedsKey = "allFeedRSSFeeds"
    private static let videosKey = "allFeedYouTubeIDs"
    private static let videosLimit = 1000
    // How many of a source's posts are new when it first joins the All feed.
    private static let firstLookCount = 20
    // How many of an RSS feed's items are new when it's first added.
    private static let rssFirstLookCount = 5

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
    // Every video YouTube's feed had as of that earlier refresh, shown in All or not.
    // All only shows the top of the YouTube feed, so these aren't all seen.
    private var previousVideos: Set<String> = []

    // Remembers what this refresh shows, so the next refresh can tell what's new.
    // Posts from feeds that failed this time stay remembered from earlier refreshes.
    private func recordRefresh() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: Self.seenKey) ?? []
        previouslySeen = Set(stored)
        previousRefresh = defaults.object(forKey: Self.refreshedKey) as? Date
        let storedSources = Set(defaults.stringArray(forKey: Self.sourcesKey) ?? [])
        previousSources = Set(storedSources.compactMap(FeedSource.init(stored:)))
        let currentPosts = posts(combinedKeys)
        defaults.set(Array(storedSources.union(currentPosts.map(\.source.rawValue))), forKey: Self.sourcesKey)
        let current = currentPosts.map(\.id)
        let currentSet = Set(current)
        let updated = stored.filter { !currentSet.contains($0) } + current
        defaults.set(Array(updated.suffix(Self.seenLimit)), forKey: Self.seenKey)
        let storedVideos = defaults.stringArray(forKey: Self.videosKey) ?? []
        previousVideos = Set(storedVideos)
        let videos = state(.youtube).posts.map(\.id)
        let videoSet = Set(videos)
        let updatedVideos = storedVideos.filter { !videoSet.contains($0) } + videos
        defaults.set(Array(updatedVideos.suffix(Self.videosLimit)), forKey: Self.videosKey)
        let now = Date()
        defaults.set(now, forKey: Self.refreshedKey)
        lastRefresh = now
        pagedSinceRefresh = []
        sendSeen()
    }

    // Offers this device's seen ids to sync with other devices, when it's on.
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

    // Adds posts the All feed has taken in since its latest refresh, so the next refresh
    // doesn't call them new.
    private func rememberSeen(_ posts: [FeedPost]) {
        let defaults = UserDefaults.standard
        let ids = posts.map(\.id)
        let idSet = Set(ids)
        let stored = (defaults.stringArray(forKey: Self.seenKey) ?? []).filter { !idSet.contains($0) }
        defaults.set(Array((stored + ids).suffix(Self.seenLimit)), forKey: Self.seenKey)
        sendSeen()
    }

    // Splits the All feed into posts new since the previous refresh and those already seen.
    // Reddit ranks posts, and RSS items can arrive dated earlier, so an older post can be new to the feed.
    // YouTube orders videos by when they went up, but can add one to the feed well after
    // that, below videos already seen, so a new video is one above the newest video seen
    // or one the feed didn't have at the previous refresh, above the deepest video it did
    // have. Videos the feed had but All never showed, further down than it reached, aren't
    // new. Age alone can't say whether
    // a video arrived since the previous refresh; that's the fallback only when none of
    // the videos were seen before.
    // A source new to the feed, like one just logged into or turned on, starts with its
    // first posts new so the feed doesn't look empty; the rest join the earlier posts.
    // Before anything's been seen every source is new to the feed. From the next refresh
    // it goes by what's new since like the rest. Nothing's hidden: the seen posts follow
    // the new ones below a line at the previous refresh.
    func splitByRefresh(_ posts: [FeedPost]) -> (new: [FeedPost], seen: [FeedPost]) {
        let firstUse = previousRefresh == nil || previouslySeen.isEmpty
        var firstLook = Set<String>()
        var counts: [FeedSource: Int] = [:]
        for post in posts where firstUse || !previousSources.contains(post.source) {
            guard counts[post.source, default: 0] < Self.firstLookCount else { continue }
            counts[post.source, default: 0] += 1
            if !previouslySeen.contains(post.id) && !pagedSinceRefresh.contains(post.id) {
                firstLook.insert(post.id)
            }
        }
        guard let previousRefresh, !firstUse else {
            return (posts.filter { firstLook.contains($0.id) }, posts.filter { !firstLook.contains($0.id) })
        }
        let cutoff = previousRefresh.timeIntervalSince1970
        let videos = state(.youtube).posts
        let newestSeenVideo = videos.firstIndex { previouslySeen.contains($0.id) }
        let videosAboveSeen = Set(videos.prefix(newestSeenVideo ?? 0).map(\.id))
        // Videos further down than the previous refresh reached are older than anything it had,
        // not added since; this keeps a deeper fetch from calling them all new.
        let deepestPreviousVideo = videos.lastIndex { previousVideos.contains($0.id) }
        let videosWithinPrevious = Set(videos.prefix((deepestPreviousVideo ?? -1) + 1).map(\.id))
        func isNew(_ post: FeedPost) -> Bool {
            if !previousSources.contains(post.source) { return firstLook.contains(post.id) }
            if previouslySeen.contains(post.id) || pagedSinceRefresh.contains(post.id) { return false }
            if post.source == .youtube {
                if newestSeenVideo != nil {
                    return videosAboveSeen.contains(post.id)
                        || (videosWithinPrevious.contains(post.id) && !previousVideos.contains(post.id))
                }
                if let publishedAt = post.publishedAt { return publishedAt > cutoff }
            }
            return true
        }
        return (posts.filter(isNew), posts.filter { !isNew($0) })
    }

    // Updates whether each source is logged in. Logging in doesn't load anything; a feed
    // that failed for want of the login says to pull down instead of showing that error.
    func refreshLoginStatus() async {
        let before = loggedIn
        for source in FeedSource.allCases {
            loggedIn[source] = await session.isLoggedIn(source)
            loginCookies[source] = await session.loginCookies(source)
        }
        for (key, state) in feeds where before[key.source] == false && loggedIn[key.source] == true
            && state.error != nil && !state.loading {
            var state = state
            state.error = nil
            state.notice = "Logged in. Pull down to load."
            feeds[key] = state
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
