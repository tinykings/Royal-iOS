import SafariServices
import SwiftUI
import WebKit

struct FeedListView<Trailing: View>: View {
    @EnvironmentObject private var store: FeedStore
    @Environment(\.openURL) private var openURL
    @State private var browserURL: BrowserURL?
    @State private var scrolledAway = false
    // A refresh asked for by pulling the feed down; its status
    // shows in the header until a moment after it's done.
    @State private var refresh: RefreshRun?
    // The All feed shows just its unread posts until this is set.
    @State private var showEarlier = false
    // How far past the end the feed is pulled up, to mark it read or show earlier posts.
    @State private var pullUp: CGFloat = 0
    // How far past the top the feed is pulled down, to refresh.
    @State private var pullDown: CGFloat = 0
    // Marking read sends the feed up and off the top, then brings in the emptied feed.
    @State private var sweptAway = false
    @State private var sweepDone = false
    @State private var sweepSettled = false
    @State private var listFadingIn = false
    // Counts down to showing the saved posts after a refresh of the All feed finds nothing new.
    @State private var nothingNewCountdown: Int?
    @State private var nothingNewTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.cards
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.cards
    @AppStorage(Preference.rssLayout) private var rssLayout = FeedLayout.cards
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.rssOpen) private var rssOpen = RSSOpenTarget.description
    // The RSS description showing.
    @State private var descriptionPost: FeedPost?
    @AppStorage(Preference.youtubePlayback) private var youtubePlayback = VideoPlayback.inApp
    @AppStorage(Preference.listWhilePlaying) private var listWhilePlaying = true
    let title: String
    // The tab showing this feed; tapping it again scrolls to the top.
    let tab: AppTab
    let keys: [FeedKey]
    var showsSource = false
    // Shows the saved posts instead of the feeds in `keys`.
    var savedOnly = false
    // The header toggle's current choice, shown beside the title since the toggles are icons.
    var subtitle: String? = nil
    // A menu to show in place of the title.
    var titleMenu: AnyView? = nil
    // What to say when the feed has nothing to show, in place of "No posts to show."
    var emptyText: String? = nil
    // Called when a pull to refresh of the All feed brings nothing new, after a short countdown.
    var onNothingNew: (() -> Void)? = nil
    // Optional nav bar control; when present the title moves to the leading edge.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let posts = savedOnly ? store.savedPosts : store.posts(keys)
        // The header slides away while scrolling down, leaving more room for the feed,
        // and comes back on scrolling up, so its controls stay in reach during a video.
        let headerHidden = scrolledAway
        // Feeds needing an account start with a card for logging in, in place of their errors.
        let loggedOut = savedOnly ? [] : [FeedSource.reddit, .youtube].filter { source in
            keys.contains { $0.source == source } && store.loggedIn[source] == false
        }
        // The All feed opens with the time of its latest refresh, and puts posts
        // new since the previous refresh first.
        let isAll = tab == .all && !savedOnly && !keys.isEmpty
        // Every source turned off in Settings leaves the All feed with nothing to show.
        let noSources = tab == .all && !savedOnly && keys.isEmpty
        // Until sources are chosen, the All feed offers to turn on the ones that start off.
        let offered = tab == .all && !savedOnly && !store.sourcesChosen
            ? FeedSource.allCases.filter { !store.isEnabled($0) } : []
        let split = isAll ? store.splitByRefresh(posts) : nil
        // Posts seen before stay tucked away until asked for. Until the feed's first been marked
        // read they show when nothing's new, so a new install's feed doesn't start out empty.
        let collapsed = !showEarlier && split.map {
            !$0.new.isEmpty || (store.hasMarkedRead && !$0.seen.isEmpty)
        } == true
        // Pulling up past the end marks unread posts read; only an empty feed shows earlier ones.
        let hasUnread = split?.new.isEmpty == false
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Where tapping the tab again scrolls to.
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topID)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if noSources {
                        NoSourcesCard()
                    } else if !loggedOut.isEmpty || !offered.isEmpty {
                        LoginCard(sources: loggedOut, offered: offered, keys: keys)
                    }
                    ForEach(savedOnly ? [] : keys, id: \.self) { key in
                        // A feed reloading after an error, such as just after logging in, shows
                        // that it's refreshing rather than the error it's about to replace.
                        if store.state(key).error != nil, store.state(key).loading, !loggedOut.contains(key.source) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Refreshing \(key.source.title)…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        } else if let error = store.state(key).error, !loggedOut.contains(key.source) {
                            Section {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(key.source.title): \(error)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Button("Settings") { store.selectedTab = .settings }
                                        .font(.footnote)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    if savedOnly && posts.isEmpty {
                        Text("No saved posts yet. Swipe left on a post, or press and hold it, to save it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 40)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if posts.isEmpty && keys.contains(where: { store.state($0).loading && store.state($0).error == nil }) {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if posts.isEmpty && loggedOut.isEmpty && !noSources
                                && keys.allSatisfy({ store.state($0).loaded && !store.state($0).loading && store.state($0).error == nil }) {
                        // A quiet subreddit can have nothing in Top today.
                        Text(emptyText ?? "No posts to show.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 40)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    // Reaching any of the last rows fetches the next page; while earlier
                    // posts are tucked away, the feed ends at the unread ones and doesn't page.
                    let shown = split.map { $0.new + $0.seen } ?? posts
                    let endIDs = collapsed ? [] : Set(shown.suffix(8).map(\.id))
                    if let split {
                        ForEach(split.new) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                        if collapsed {
                            if hasUnread {
                                MarkReadButton(pullable: Self.canPull, pullProgress: pullUp / Self.pullThreshold) {
                                    markRead(proxy)
                                }
                            } else {
                                EarlierPostsButton(date: store.previousRefresh, pullable: Self.canPull,
                                                   pullProgress: pullUp / Self.pullThreshold) {
                                    revealEarlier(proxy)
                                }
                            }
                        } else {
                            if !split.new.isEmpty && !split.seen.isEmpty, let previous = store.previousRefresh {
                                RefreshDivider(prefix: "Previous refresh", date: previous)
                                    .id(Self.earlierID)
                            } else {
                                Color.clear
                                    .frame(height: 0)
                                    .id(Self.earlierID)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            ForEach(split.seen) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                        }
                    } else {
                        ForEach(posts) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                    }
                    if !savedOnly && !posts.isEmpty && !collapsed {
                        moreStatus
                    }
                }
                .listStyle(.plain)
                // Lets the top anchor take no space; posts are taller than the default minimum.
                .environment(\.defaultMinListRowHeight, 0)
                // Posts sit on tiles over the grouped background.
                .scrollContentBackground(.hidden)
                .visualEffect { [sweptAway, reduceMotion] content, geometry in
                    content.offset(y: sweptAway && !reduceMotion ? -geometry.size.height : 0)
                }
                .opacity(sweptAway || listFadingIn || nothingNewCountdown != nil ? 0 : 1)
                .overlay {
                    if let seconds = nothingNewCountdown {
                        NothingNewView(seconds: seconds)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: nothingNewCountdown == nil)
                .background(Color(.systemGroupedBackground))
                .hidesHeaderOnScroll($scrolledAway)
                // Pulling up past the unread posts marks them read, and pulling up the empty
                // feed then shows the earlier ones, like pulling down refreshes.
                .pullPast(.bottom, enabled: collapsed, distance: $pullUp, threshold: Self.pullThreshold,
                          settleFirst: true, onRelease: {
                    if hasUnread { sweepAway(proxy) }
                }) {
                    if hasUnread || sweptAway {
                        sweepSettled = true
                        finishSweep(proxy)
                    } else {
                        revealEarlier(proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    if collapsed && pullUp > 0 {
                        Group {
                            if hasUnread {
                                PullIndicator.markRead(distance: pullUp, threshold: Self.pullThreshold)
                            } else {
                                PullIndicator.earlier(distance: pullUp, threshold: Self.pullThreshold)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Pulling down past the top refreshes, with the king coming down into the gap in
                // place of the system spinner, like the horse from the bottom. Only a drag counts,
                // so the bounce after a fling leaves it alone.
                .pullPast(.top, enabled: refresh?.finished != false, distance: $pullDown,
                          threshold: Self.pullThreshold, whileDragging: true) {
                    Task { await refreshFeeds() }
                }
                .overlay(alignment: .top) {
                    if pullDown > 0 {
                        PullIndicator.refresh(distance: pullDown, threshold: Self.pullThreshold)
                            .allowsHitTesting(false)
                    }
                }
                // Tapping the tab again scrolls to the top.
                .onChange(of: store.reselected?.count) {
                    guard store.reselected?.tab == tab else { return }
                    withAnimation { proxy.scrollTo(Self.topID, anchor: .top) }
                    scrolledAway = false
                }
                // Keep header visibility changes out of the list's animation transaction.
                // Animating the whole List can fade/reposition its lazily measured rows
                // when the navigation bar changes the scroll view's insets.
                .toolbar(headerHidden ? .hidden : .visible, for: .navigationBar)
                .alert("Couldn't change subscription", isPresented: Binding(
                    get: { store.subscribeError != nil && keys.contains(.youtubeHome) },
                    set: { if !$0 { store.subscribeError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.subscribeError ?? "")
                }
                .navigationTitle(Trailing.self == EmptyView.self ? title : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if Trailing.self != EmptyView.self {
                        PlainToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: 8) {
                                if let titleMenu {
                                    titleMenu
                                } else {
                                    Text(title)
                                        .font(.headline)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                // A refresh's status takes the place of what's normally here. With
                                // a subreddit's name showing, there's only room for its icon.
                                if let status = refreshStatus(split: split, loggedOut: loggedOut,
                                                              showsText: titleMenu == nil || subtitle != nil) {
                                    status
                                } else {
                                    if let subtitle {
                                        Text(subtitle)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    if savedOnly {
                                        SavedOnWebLink()
                                    }
                                    // The All feed's latest refresh.
                                    if isAll, let refresh = store.lastRefresh, !posts.isEmpty {
                                        Text(RefreshDivider.time(refresh))
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                            .accessibilityLabel("Last refresh \(RefreshDivider.time(refresh))")
                                    }
                                }
                            }
                            .fixedSize()
                            .animation(.easeInOut(duration: 0.25), value: refresh)
                        }
                        PlainToolbarItem(placement: .topBarTrailing) {
                            trailing
                        }
                    }
                    // No controls here and a centered title, so the status has this side to itself.
                    if Trailing.self == EmptyView.self {
                        PlainToolbarItem(placement: .topBarTrailing) {
                            refreshStatus(split: split, loggedOut: loggedOut, showsText: true)
                                .fixedSize()
                                .animation(.easeInOut(duration: 0.25), value: refresh)
                        }
                    }
                }
                .systemRefreshable(!Self.canPull) { await refreshFeeds() }
                // Back to the top once refreshed, where new posts land; the list otherwise
                // keeps the rows that were showing in view, leaving new ones above them.
                .onChange(of: refresh?.finished) { _, finished in
                    if finished == true { proxy.scrollTo(Self.topID, anchor: .top) }
                }
                // Each refresh starts with just the unread posts again.
                .onChange(of: store.lastRefresh) { showEarlier = false }
                .onChange(of: savedOnly) { cancelNothingNew() }
                .onDisappear { cancelNothingNew() }
                .task(id: keys) { await store.load(keys) }
                .sheet(item: $descriptionPost) { post in
                    RSSDescriptionView(post: post)
                }
                .fullScreenCover(item: $browserURL) { item in
                    AppBrowser(url: item.url)
                        // Clear so the feed shows behind while swiping the browser away.
                        .presentationBackground(.clear)
                }
            }
        }
    }

    private static var topID: String { "top" }
    private static var pullThreshold: CGFloat { 90 }
    // Pulling past the ends needs iOS 18's scroll geometry; earlier versions keep the
    // buttons for marking read and earlier posts, and the system's pull to refresh.
    private static var canPull: Bool {
        if #available(iOS 18, *) { true } else { false }
    }

    // Clears the unread posts, leaving the empty feed at the top.
    private func markRead(_ proxy: ScrollViewProxy) {
        store.markAllRead()
        pullUp = 0
        scrolledAway = false
        DispatchQueue.main.async {
            proxy.scrollTo(Self.topID, anchor: .top)
        }
    }

    // Letting go of a pull to mark read sends the feed up and away while the bounce settles;
    // once both are done the posts are marked read and the empty feed fades in.
    private func sweepAway(_ proxy: ScrollViewProxy) {
        sweepDone = false
        sweepSettled = false
        withAnimation(.easeIn(duration: 0.3)) {
            sweptAway = true
        } completion: {
            sweepDone = true
            finishSweep(proxy)
        }
    }

    private func finishSweep(_ proxy: ScrollViewProxy) {
        guard sweptAway else { return markRead(proxy) }
        guard sweepDone && sweepSettled else { return }
        markRead(proxy)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            sweptAway = false
            sweepDone = false
            sweepSettled = false
            listFadingIn = true
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { listFadingIn = false }
        }
    }

    // Shows the posts from earlier refreshes and starts at the first of them.
    private func revealEarlier(_ proxy: ScrollViewProxy) {
        showEarlier = true
        pullUp = 0
        DispatchQueue.main.async {
            proxy.scrollTo(Self.earlierID, anchor: .top)
        }
    }
    // Where the earlier posts begin once shown.
    private static var earlierID: String { "earlier" }

    private func refreshFeeds() async {
        let run = RefreshRun(id: (refresh?.id ?? 0) + 1)
        refresh = run
        cancelNothingNew()
        await store.load(keys, force: true)
        guard refresh?.id == run.id else { return }
        refresh?.finished = true
        if nothingNew { startNothingNew() }
        // Leaves the results up long enough to pass through them all, unless another
        // refresh has begun since.
        let linger = max(3, Double(keys.count) * RefreshStatus.interval)
        Task {
            try? await Task.sleep(for: .seconds(linger))
            if refresh?.id == run.id { refresh = nil }
        }
    }

    // Whether the All feed's refresh just now found no new posts. A refresh where every
    // feed failed hasn't shown there's nothing new, so it doesn't count.
    private var nothingNew: Bool {
        guard onNothingNew != nil, tab == .all, !savedOnly,
              keys.contains(where: { store.state($0).loaded && store.state($0).error == nil }) else { return false }
        let posts = store.posts(keys)
        return store.splitByRefresh(posts).new.isEmpty
    }

    // Says there's nothing new, counts down from 3, then shows the saved posts.
    private func startNothingNew() {
        nothingNewTask?.cancel()
        nothingNewCountdown = 3
        nothingNewTask = Task {
            for seconds in [2, 1] {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                nothingNewCountdown = seconds
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            onNothingNew?()
            nothingNewCountdown = nil
            nothingNewTask = nil
        }
    }

    private func cancelNothingNew() {
        nothingNewTask?.cancel()
        nothingNewTask = nil
        nothingNewCountdown = nil
    }

    // The header's status while a refresh runs and a moment after.
    private func refreshStatus(split: (new: [FeedPost], seen: [FeedPost])?, loggedOut: [FeedSource],
                               showsText: Bool) -> RefreshStatus? {
        guard let refresh, !savedOnly else { return nil }
        let items = statusItems(finished: refresh.finished, split: split, loggedOut: loggedOut)
        guard !items.isEmpty else { return nil }
        return RefreshStatus(items: items, finished: refresh.finished, showsSource: keys.count > 1, showsText: showsText)
    }

    // Each feed's progress; once done, the All feed counts what's new from each.
    private func statusItems(finished: Bool, split: (new: [FeedPost], seen: [FeedPost])?,
                             loggedOut: [FeedSource]) -> [RefreshStatus.Item] {
        keys.filter { !loggedOut.contains($0.source) }.map { key in
            let state = store.state(key)
            let phase: RefreshStatus.Phase
            if state.loading {
                phase = .loading
            } else if state.error != nil {
                phase = .failed
            } else {
                phase = .done(new: finished ? split?.new.filter { $0.source == key.source }.count : nil)
            }
            return RefreshStatus.Item(source: key.source, phase: phase)
        }
    }

    // At the end of the list: a spinner while the next page loads, or a retry button
    // when it failed.
    @ViewBuilder
    private var moreStatus: some View {
        let states = keys.map { store.state($0) }
        if states.contains(where: \.loadingMore) {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else if states.contains(where: { $0.moreError != nil }) {
            Button {
                Task { await store.loadMore(keys, retry: true) }
            } label: {
                Label("Couldn't load more. Try Again", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func postRow(_ post: FeedPost, nearEnd: Bool) -> some View {
        let isSaved = store.isSaved(post)
        return PostRow(post: post, showsSource: showsSource, showsDate: !savedOnly, layout: layout(for: post), saved: isSaved,
                       playing: store.playingVideo?.id == post.id)
            .contentShape(RoundedRectangle(cornerRadius: PostRow.cornerRadius))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: PostRow.cornerRadius))
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onTapGesture { open(post) }
            .onAppear {
                if nearEnd && !savedOnly { Task { await store.loadMore(keys) } }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                saveButton(for: post, isSaved: isSaved)
                    .tint(.pink)
                subscribeButton(for: post)
            }
            // Swiping right offers what a tap doesn't, per Settings.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                alternateActions(for: post)
            }
            .contextMenu {
                saveButton(for: post, isSaved: isSaved)
                subscribeButton(for: post)
                alternateActions(for: post)
            }
    }

    private func layout(for post: FeedPost) -> FeedLayout {
        // Compact rows leave more of the feed visible under the mini player.
        // Saved mixes every source, so it stays compact.
        if savedOnly { return .list }
        if listWhilePlaying && store.playingVideo != nil { return .list }
        switch post.source {
        case .reddit: return redditLayout
        case .youtube: return youtubeLayout
        case .rss: return rssLayout
        }
    }

    private func saveButton(for post: FeedPost, isSaved: Bool) -> some View {
        Button {
            withAnimation { store.toggleSaved(post) }
        } label: {
            Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "heart.slash" : "heart")
        }
    }

    // On YouTube's recommendations, following the video's channel, or no longer following it.
    @ViewBuilder
    private func subscribeButton(for post: FeedPost) -> some View {
        if keys.contains(.youtubeHome), post.source == .youtube, let channel = post.channelId {
            let subscribed = store.isSubscribed(post)
            Button {
                Task { await store.toggleSubscribed(post) }
            } label: {
                Label(subscribed ? "Unsubscribe" : "Subscribe",
                      systemImage: subscribed ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus")
            }
            .tint(subscribed ? .gray : .blue)
            .disabled(store.subscribing.contains(channel))
        }
    }

    // The open options a tap doesn't use: the other of link/comments, or for a video,
    // its YouTube page in a Safari view without leaving the app. RSS offers the other
    // of description/link.
    @ViewBuilder
    private func alternateActions(for post: FeedPost) -> some View {
        if post.source == .rss {
            if rssOpen == .link {
                Button { descriptionPost = post } label: { Label("Open description", systemImage: "doc.text") }
                    .tint(.blue)
            } else {
                Button { openInBrowser(post.url) } label: { Label("Open link", systemImage: "link") }
                    .tint(.blue)
            }
        } else if post.source == .youtube {
            Button {
                if let url = URL(string: post.url) { SafariView.present(url) }
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
            .tint(.blue)
        } else if openTarget(for: post) == .comments {
            Button { openInBrowser(post.url) } label: { Label("Open link", systemImage: "link") }
                .tint(.blue)
        } else {
            Button { openInBrowser(post.commentsUrl) } label: { Label("Open comments", systemImage: "bubble.left.and.bubble.right") }
                .tint(.blue)
        }
    }

    private func openTarget(for post: FeedPost) -> OpenTarget {
        redditOpen
    }

    // Videos play where Settings says; Reddit opens its link or comments, and RSS its
    // description or link, per Settings.
    private func open(_ post: FeedPost) {
        if post.source == .youtube {
            play(post, with: youtubePlayback)
        } else if post.source == .rss {
            if rssOpen == .description { descriptionPost = post } else { openInBrowser(post.url) }
        } else {
            openInBrowser(openTarget(for: post) == .comments ? post.commentsUrl : post.url)
        }
    }

    private func play(_ post: FeedPost, with playback: VideoPlayback) {
        guard let videoId = post.videoId, let watchURL = URL(string: post.url) else {
            if let url = URL(string: post.url) { openURL(url) }
            return
        }
        switch playback {
        case .inApp:
            store.playingVideo = post
        case .browser:
            // x-safari-https opens Safari directly instead of handing the link to the YouTube app.
            let safariURL = URL(string: "x-safari-" + watchURL.absoluteString) ?? watchURL
            openURL(safariURL) { accepted in
                if !accepted { openURL(watchURL) }
            }
        case .youtubeApp:
            let appURL = URL(string: "youtube://www.youtube.com/watch?v=\(videoId)")!
            // Without the YouTube app installed, fall back to the web link.
            openURL(appURL) { accepted in
                if !accepted { openURL(watchURL) }
            }
        }
    }

    private func openInBrowser(_ string: String) {
        guard let url = URL(string: string) else { return }
        if !["http", "https"].contains(url.scheme ?? "") {
            openURL(url)
        } else {
            // Reddit pages open with the app's login, so voting and replying work; the
            // Safari view has Safari's own logins. Other sites get Safari's reader and blockers.
            // Reddit's media links (v.redd.it, i.redd.it) redirect to the post on reddit.com.
            let host = url.host ?? ""
            let reddit = ["reddit.com", "redd.it"].contains { host == $0 || host.hasSuffix("." + $0) }
            if reddit {
                browserURL = BrowserURL(url: url)
            } else {
                SafariView.present(url)
            }
        }
    }
}

extension FeedListView where Trailing == EmptyView {
    init(title: String, tab: AppTab, keys: [FeedKey], showsSource: Bool = false) {
        self.init(title: title, tab: tab, keys: keys, showsSource: showsSource, savedOnly: false) { EmptyView() }
    }
}

private struct ScrollPosition: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
    var insetTop: CGFloat
}

extension View {
    // Sets `hidden` while scrolling down and clears it when scrolling up or reaching
    // the top. Needs iOS 18 scroll geometry; earlier versions keep the header.
    @ViewBuilder
    func hidesHeaderOnScroll(_ hidden: Binding<Bool>) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: ScrollPosition.self) { geometry in
                ScrollPosition(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                               maxOffset: geometry.contentSize.height - geometry.containerSize.height
                                   + geometry.contentInsets.top + geometry.contentInsets.bottom,
                               insetTop: geometry.contentInsets.top)
            } action: { old, new in
                let delta = new.offset - old.offset
                if new.insetTop != old.insetTop || new.maxOffset != old.maxOffset {
                    // The header appeared or disappeared, or rows resized and the list moved
                    // to keep its place; neither is the user scrolling.
                } else if new.offset <= 0 {
                    hidden.wrappedValue = false
                } else if new.offset >= new.maxOffset {
                    // Ignore the bounce at the bottom so it doesn't flicker the header.
                } else if delta > 2 && new.offset > 60 {
                    hidden.wrappedValue = true
                } else if delta < -2 {
                    hidden.wrappedValue = false
                }
            }
        } else {
            self
        }
    }
}

extension View {
    // Sets `distance` to how far the list is dragged past its top or end, and calls
    // `action` when let go past `threshold`. The list's own bounce gives the pull its
    // resistance. With `settleFirst` the action waits for the bounce back to settle, which
    // would otherwise carry the list on past where the action scrolls it to. With
    // `whileDragging` the distance only counts during a drag, and is 0 once let go.
    // `onRelease` runs the moment it's let go past `threshold`, before any settling. Needs
    // iOS 18 scroll geometry.
    @ViewBuilder
    func pullPast(_ edge: VerticalEdge, enabled: Bool, distance: Binding<CGFloat>, threshold: CGFloat,
                  settleFirst: Bool = false, whileDragging: Bool = false,
                  onRelease: @escaping () -> Void = {},
                  action: @escaping () -> Void) -> some View {
        if #available(iOS 18, *) {
            modifier(PullPastEdge(edge: edge, enabled: enabled, distance: distance, threshold: threshold,
                                  settleFirst: settleFirst, whileDragging: whileDragging,
                                  onRelease: onRelease, action: action))
        } else {
            self
        }
    }

    // The system's pull to refresh, where the app's own pull isn't available.
    @ViewBuilder
    func systemRefreshable(_ enabled: Bool, action: @escaping @Sendable () async -> Void) -> some View {
        if enabled {
            refreshable(action: action)
        } else {
            self
        }
    }
}

@available(iOS 18, *)
private struct PullPastEdge: ViewModifier {
    let edge: VerticalEdge
    let enabled: Bool
    @Binding var distance: CGFloat
    let threshold: CGFloat
    let settleFirst: Bool
    let whileDragging: Bool
    let onRelease: () -> Void
    let action: () -> Void
    // Let go past the threshold, waiting for the list to settle.
    @State private var released = false
    @State private var dragging = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                switch edge {
                case .top:
                    return max(0, -offset)
                case .bottom:
                    // A list shorter than the screen ends at its top.
                    let end = max(0, geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height)
                    return max(0, offset - end)
                }
            } action: { _, new in
                distance = enabled && (dragging || !whileDragging) ? new : 0
            }
            .onScrollPhaseChange { old, new in
                dragging = new == .interacting
                // Counts on letting go, so pulling back before then calls it off.
                if old == .interacting && new != .interacting && enabled && distance >= threshold {
                    onRelease()
                    if settleFirst {
                        released = true
                    } else {
                        action()
                    }
                }
                if new == .idle && released {
                    released = false
                    action()
                } else if new == .interacting {
                    released = false
                }
                if whileDragging && new != .interacting { distance = 0 }
            }
    }
}

// A toolbar item without the glass bubble iOS 26 draws behind toolbar items, which
// would otherwise wrap the title and double up behind the segmented sort control.
struct PlainToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: Content

    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: placement) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content }
        }
    }
}

// A page for AppBrowser, which shares the app's logins.
struct BrowserURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// A browser on the app's web profile, so pages see the logins made in the app.
// Swiping in from the left edge goes back a page, or on the first page closes the
// browser, sliding it off to show the feed behind.
struct AppBrowser: View {
    let url: URL
    @StateObject private var page = BrowserPage()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    // How far the edge swipe has pulled the browser to the right.
    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        let current = page.url ?? url
        GeometryReader { geometry in
            let width = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            browser(current, width: width)
                .background(Color(.systemBackground), ignoresSafeAreaEdges: .all)
                .shadow(color: .black.opacity(swipeOffset > 0 ? 0.25 : 0), radius: 10)
                .offset(x: swipeOffset)
        }
    }

    // Follows the swipe, then either slides the browser away or springs it back.
    private func edgeSwipe(width: CGFloat) -> EdgeSwipe {
        EdgeSwipe(
            changed: { swipeOffset = max($0, 0) },
            ended: { translation, velocity in
                if translation > width / 3 || velocity > 600 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        swipeOffset = width
                    } completion: {
                        // Already off screen; the cover's own slide down would bring it back into view.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { dismiss() }
                    }
                } else {
                    withAnimation(.spring(duration: 0.25)) { swipeOffset = 0 }
                }
            })
    }

    private func browser(_ current: URL, width: CGFloat) -> some View {
        NavigationStack {
            BrowserWebView(url: url, page: page, edgeSwipe: edgeSwipe(width: width))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(current.host.map { $0.replacingOccurrences(of: "www.", with: "") } ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Back", systemImage: "chevron.backward") { page.webView?.goBack() }
                            .disabled(!page.canGoBack)
                        Button("Forward", systemImage: "chevron.forward") { page.webView?.goForward() }
                            .disabled(!page.canGoForward)
                        Spacer()
                        ShareLink(item: current)
                        Button("Open in Safari", systemImage: "safari") {
                            // x-safari-https opens Safari rather than handing the link to an app.
                            let safari = URL(string: "x-safari-" + current.absoluteString) ?? current
                            openURL(safari) { accepted in
                                if !accepted { openURL(current) }
                            }
                        }
                    }
                }
        }
    }
}

// Tracks the browser's page so the toolbar can follow it.
@MainActor
final class BrowserPage: ObservableObject {
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    private(set) weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func attach(_ webView: WKWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }
}

// Reports a swipe in from the left edge, which the browser uses to close.
struct EdgeSwipe {
    // The swipe's distance so far.
    let changed: (CGFloat) -> Void
    // Its final distance and speed.
    let ended: (CGFloat, CGFloat) -> Void
}

private struct BrowserWebView: UIViewRepresentable {
    let url: URL
    let page: BrowserPage
    let edgeSwipe: EdgeSwipe

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebProfile.configuration())
        // Swiping from the left edge goes back while there's a page to go back to.
        webView.allowsBackForwardNavigationGestures = true
        // On the first page it closes the browser instead.
        let pan = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.edges = .left
        pan.delegate = context.coordinator
        webView.addGestureRecognizer(pan)
        page.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.edgeSwipe = edgeSwipe
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(edgeSwipe: edgeSwipe)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var edgeSwipe: EdgeSwipe

        init(edgeSwipe: EdgeSwipe) {
            self.edgeSwipe = edgeSwipe
        }

        @objc func pan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view.window).x
            switch recognizer.state {
            case .changed:
                edgeSwipe.changed(translation)
            case .ended:
                edgeSwipe.ended(translation, recognizer.velocity(in: view.window).x)
            case .cancelled, .failed:
                edgeSwipe.ended(0, 0)
            default:
                break
            }
        }

        // The web view's own back swipe handles the edge while it can go back.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            !((recognizer.view as? WKWebView)?.canGoBack ?? false)
        }
    }
}

// Pages outside Reddit open in a Safari view, presented by UIKit rather than as a
// SwiftUI cover so it keeps its own swipe in from the left edge to close.
@MainActor
enum SafariView {
    static func present(_ url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(SFSafariViewController(url: url), animated: true)
    }
}

// Login buttons for logged-out feeds; the feed reloads once a login sticks.
// Sits beside "Saved" in the header: the Royal Saved website shows the same saved
// posts, synced through iCloud, in a browser. Opens in Safari, where its Apple
// sign-in stays.
struct SavedOnWebLink: View {
    static let url = URL(string: "https://royal.tinyk.ing/saved/")!

    var body: some View {
        Link(destination: Self.url) {
            HStack(spacing: 3) {
                Text("On the web")
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tint)
        }
        .accessibilityHint("Opens your saved posts at royal.tinyk.ing in Safari")
    }
}

struct LoginCard: View {
    @EnvironmentObject private var store: FeedStore
    @State private var loggingIn: FeedSource?
    let sources: [FeedSource]
    // Sources that are off, offered to turn on; only on the All feed before sources are chosen.
    var offered: [FeedSource] = []
    // The feeds to reload once logged in.
    let keys: [FeedKey]
    private var title: String {
        if !offered.isEmpty { return "Set up your feeds" }
        return keys.count > 1 ? "Log in to see your feeds" : "Log in to \(sources[0].title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                Button {
                    loggingIn = source
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text("Log in to \(source.title)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            // Turning one on adds it to the feed, and counts as choosing sources, so
            // these offers go away; Settings has the rest.
            ForEach(offered) { source in
                Button {
                    withAnimation { store.setEnabled(source, true) }
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Turn on \(source.title)")
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PostRow.cornerRadius))
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // Check the login cookies once the page is closed.
        .sheet(item: $loggingIn, onDismiss: checkLogin) { source in
            NavigationStack {
                LoginPage(title: source.title, url: source.loginURL!)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { loggingIn = nil }
                        }
                    }
            }
        }
    }

    // Kept short; the title says what to log in to, and closing the page is what
    // checks the login and reloads the feed.
    private var message: String {
        sources.isEmpty ? "Turn on the sources you'd like in your feed." : "Once logged in, tap Done."
    }

    private func checkLogin() {
        Task { await store.finishLogin(sources, reloading: keys) }
    }
}

struct RefreshRun: Equatable {
    let id: Int
    var finished = false
}

// In the header during a refresh: each source's progress, then how it went, one at a time.
struct RefreshStatus: View {
    enum Phase: Equatable {
        case loading
        // How many posts are new, where the feed tells new from seen.
        case done(new: Int?)
        case failed
    }

    struct Item: Identifiable {
        let source: FeedSource
        let phase: Phase
        var id: FeedSource { source }
    }

    // Seconds each source stays up before the next scrolls in.
    static let interval = 1.5

    // Never empty; the feed leaves the status out when no source is refreshing.
    let items: [Item]
    let finished: Bool
    // Off where the title already names the only source.
    var showsSource = true
    var showsText = true
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = items[index % items.count]
        ZStack {
            line(item)
                .id(item.source)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)))
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map { "\($0.source.title) \(detail($0.phase))" }.joined(separator: ", "))
        // Starts over with the first source when the results come in.
        .task(id: finished) {
            index = 0
            guard items.count > 1 else { return }
            while true {
                try? await Task.sleep(for: .seconds(Self.interval))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.3)) { index += 1 }
            }
        }
    }

    private func line(_ item: Item) -> some View {
        HStack(spacing: 4) {
            icon(item.phase)
                .frame(width: 14)
            if showsText {
                if showsSource {
                    Text(item.source.title)
                        .fontWeight(.medium)
                }
                Text(detail(item.phase))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private func icon(_ phase: Phase) -> some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func detail(_ phase: Phase) -> String {
        switch phase {
        case .loading: "Refreshing…"
        case .done(nil): "Updated"
        case .done(0): "Nothing new"
        case .done(let new?): "\(new) new"
        case .failed: "Couldn't refresh"
        }
    }
}

// Ends the All feed's unread posts; tapping it marks them all read.
struct MarkReadButton: View {
    // The feed marks its posts read when pulled up past here, so this is just a hint;
    // VoiceOver still offers it as a button.
    var pullable = false
    // How far the feed is pulled up, from 0 to the threshold at 1.
    var pullProgress: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Group {
            if pullable {
                Text("Pull up to mark as read")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Mark All as Read")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { action() }
            } else {
                Button(action: action) {
                    Label("Mark All as Read", systemImage: "checkmark")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .pullHintFade(pullProgress)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// Fills the All feed once nothing's unread; tapping it shows the posts from earlier refreshes.
// In the middle of the All feed when a refresh finds nothing new, counting down to the saved posts.
struct NothingNewView: View {
    let seconds: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 56))
                .foregroundStyle(.pink)
            Text("Sorry, there is nothing new to show you.")
                .font(.headline)
            Text("Loading saved in \(seconds)…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: seconds)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

struct EarlierPostsButton: View {
    // Where the earlier posts leave off.
    let date: Date?
    // The feed shows the earlier posts when pulled up past here, so this is just a hint;
    // VoiceOver still offers it as a button.
    var pullable = false
    // How far the feed is pulled up, from 0 to the threshold at 1.
    var pullProgress: CGFloat = 0
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("You're all caught up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if pullable {
                Text("Pull up for earlier posts")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Show Earlier Posts")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { action() }
            } else {
                Button(action: action) {
                    Label("Show Earlier Posts", systemImage: "chevron.down")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            if let date {
                Text("From \(RefreshDivider.time(date)) and before")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .pullHintFade(pullProgress)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

extension View {
    // The pull indicator rising from the bottom says the same thing as the hint at the end
    // of the feed, so the hint fades and drifts back as the pull begins, gone well before
    // the horse arrives, so the two never overlap.
    func pullHintFade(_ progress: CGFloat) -> some View {
        let fade = min(max(progress / 0.4, 0), 1)
        return opacity(1 - fade)
            .scaleEffect(1 - 0.06 * fade)
            .blur(radius: 3 * fade)
    }
}

// Comes in from the edge the feed is pulled away from: from the bottom, the horse fills with
// gold from the bottom up; from the top, the king fills from the top down. Once full, letting
// go does what the caption says.
struct PullIndicator: View {
    let prompt: String
    let release: String
    let distance: CGFloat
    let threshold: CGFloat
    var edge = VerticalEdge.bottom

    static func markRead(distance: CGFloat, threshold: CGFloat) -> PullIndicator {
        PullIndicator(prompt: "Pull up to mark as read", release: "Release to mark as read",
                      distance: distance, threshold: threshold)
    }

    static func earlier(distance: CGFloat, threshold: CGFloat) -> PullIndicator {
        PullIndicator(prompt: "Pull up for earlier posts", release: "Release for earlier posts",
                      distance: distance, threshold: threshold)
    }

    static func refresh(distance: CGFloat, threshold: CGFloat) -> PullIndicator {
        PullIndicator(prompt: "Pull down to refresh", release: "Release to refresh",
                      distance: distance, threshold: threshold, edge: .top)
    }

    private var isTop: Bool { edge == .top }
    private var imageName: String { isTop ? "PullKing" : "PullHorse" }
    // The art's width over its height.
    private var aspect: CGFloat { isTop ? 240 / 340 : 360 / 315 }
    private var width: CGFloat { isTop ? 48 : 80 }
    private var height: CGFloat { width / aspect }

    private var progress: CGFloat { min(distance / threshold, 1) }
    private var armed: Bool { distance >= threshold }
    private var scale: CGFloat { armed ? 1.15 : 0.7 + 0.3 * progress }
    // The laid-out height, before the art's scale.
    @State private var laidOutHeight: CGFloat = 0
    // From the top, how far it sits above where it would rest, so that its bottom, scaled art
    // included, stays a little above the top card as the gap opens and never runs over it.
    private var topOffset: CGFloat {
        let bottom = laidOutHeight + height * (scale - 1) + 6
        return min(0, distance - bottom)
    }

    var body: some View {
        VStack(spacing: 6) {
            if isTop { caption }
            ZStack {
                art
                    .opacity(0.8)
                // The art is light gray, so multiplying keeps its shading and lines in gold.
                art
                    .colorMultiply(.royalAccent)
                    .mask(alignment: isTop ? .top : .bottom) {
                        Rectangle().frame(height: height * progress)
                    }
            }
            .frame(width: width, height: height)
            .scaleEffect(scale, anchor: isTop ? .top : .center)
            if !isTop { caption }
        }
        // Clears the floating tab bar, which the list runs under; at the top, just the header.
        .padding(isTop ? .top : .bottom, isTop ? 8 : 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { laidOutHeight = $0 }
        .opacity(Double(progress))
        // Comes in with the gap the pull opens, rather than ahead of it.
        .offset(y: isTop ? topOffset : max(0, threshold - distance) * 0.6)
        .animation(.spring(duration: 0.25), value: armed)
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, armed in armed }
    }

    private var caption: some View {
        Text(armed ? release : prompt)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var art: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
    }
}

// Marks where the All feed's posts from the previous refresh begin.
struct RefreshDivider: View {
    let prefix: String
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(.tint.opacity(0.6))
            .frame(height: 1)
    }

    private var label: String {
        "\(prefix) · \(Self.time(date))"
    }

    // Just the time for today, with the date before that.
    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}

struct PostRow: View {
    let post: FeedPost
    var showsSource = false
    var showsDate = true
    var layout = FeedLayout.list
    var saved = false
    // The video in the docked player; outlined so it's easy to find in the list.
    var playing = false
    @AppStorage(Preference.feedTextSize) private var textSize = FeedTextSize.standard

    static let cornerRadius: CGFloat = 14
    private static let inset: CGFloat = 12
    // Taller images are letterboxed to a square so one image can't fill the screen.
    private static let tallestImageAspect = 1.0

    var body: some View {
        Group {
            if layout == .cards {
                card
            } else {
                row
                    // Room below a list thumbnail so the heart doesn't sit on it.
                    .padding(.bottom, saved && thumbnail != nil ? 16 : 0)
                    .padding(Self.inset)
            }
        }
        .feedTextSize(textSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if saved {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .padding(Self.inset)
                    .accessibilityLabel("Saved")
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            if playing {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(.tint, lineWidth: 2)
            } else {
                // Keeps the tile's edge in sight when an image runs dark to its edges, as a
                // screenshot of a dark app does; in dark mode it would blend into the page.
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .accessibilityValue(playing ? "Playing" : "")
    }

    // Text with a small thumbnail on the right.
    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            details
            Spacer(minLength: 0)
            if let thumbnail {
                CachedImage(url: thumbnail) { image in
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.1)
                    }
                }
                .frame(width: 96, height: 54)
                .nsfwCover(hidden: hidesImage, compact: true) { revealed = true }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // A large image across the top of the tile with the text below.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail {
                if post.videoId != nil {
                    // Video thumbnails are letterboxed 4:3; crop them to the 16:9 frame.
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            CachedImage(url: thumbnail) { image in
                                if let image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.1)
                                }
                            }
                        }
                        .clipped()
                } else {
                    // Reddit and RSS images keep their own shape, capped so tall ones don't fill the
                    // screen; narrow ones sit on a blurred copy of themselves across the tile,
                    // so the sides match the image in light and dark mode rather than leaving
                    // bars that read as a gap in the tile. The frame comes from Reddit's
                    // reported size, not the loaded image, so the tile doesn't change height
                    // when the image arrives; a list that resizes rows as you scroll back up
                    // jumps around.
                    Color.secondary.opacity(0.08)
                        .aspectRatio(max(post.imageAspect ?? 4 / 3, Self.tallestImageAspect), contentMode: .fit)
                        .overlay {
                            CachedImage(url: thumbnail) { image in
                                if let image {
                                    image.resizable().scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background {
                                            image.resizable().scaledToFill()
                                                .blur(radius: 24, opaque: true)
                                                .overlay(Color.black.opacity(0.15))
                                        }
                                }
                            }
                        }
                        .nsfwCover(hidden: hidesImage) { revealed = true }
                        .clipped()
                }
            }
            details
                .padding(Self.inset)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.title)
                .font(layout == .cards ? .headline : .body)
            // Baseline-aligned so the icon stays on the first line when the details wrap.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                } else if showsSource {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                }
                Text(meta)
                    .foregroundStyle(.secondary)
            }
            // Keeps the meta line clear of the heart in the corner.
            .padding(.trailing, saved ? 18 : 0)
            .font(.caption)
        }
    }

    private var icon: String {
        switch post.source {
        case .reddit: "r.circle.fill"
        case .rss: "dot.radiowaves.up.forward"
        case .youtube: "play.rectangle.fill"
        }
    }

    private var color: Color {
        switch post.source {
        case .reddit: .orange
        case .rss: .teal
        case .youtube: .red
        }
    }

    private var thumbnail: URL? {
        // hqdefault exists for every video; larger sizes can be missing.
        if let videoId = post.videoId { return URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg") }
        return post.image.flatMap(URL.init(string:))
    }

    // NSFW images stay blurred until tapped.
    @State private var revealed = false
    private var hidesImage: Bool { post.nsfw == true && !revealed }

    private var meta: String {
        var parts = [post.label]
        if post.nsfw == true { parts.append("NSFW") }
        if let score = post.score { parts.append(Self.count(score, "pt")) }
        if let comments = post.comments { parts.append(Self.count(comments, "comment")) }
        if showsDate {
            if let created = post.created { parts.append(Self.age(Date().timeIntervalSince1970 - created)) }
            if let published = post.published, !published.isEmpty { parts.append(Self.shortAge(published, publishedAt: post.publishedAt)) }
        }
        return parts.joined(separator: " · ")
    }

    // "1 comment", "12 comments", "1.2K comments".
    private static func count(_ value: Int, _ noun: String) -> String {
        let number = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        return "\(number) \(noun)\(value == 1 ? "" : "s")"
    }

    private static let ageUnits: [(seconds: Double, suffix: String)] = [
        (31_536_000, "y"), (2_592_000, "mo"), (604_800, "w"), (86_400, "d"), (3_600, "h"), (60, "m"),
    ]

    // Ages in the largest whole unit: "now", "5m", "3h", "2d", "4w", "3mo", "1y".
    private static func age(_ seconds: Double) -> String {
        for unit in ageUnits where seconds >= unit.seconds {
            return "\(Int(seconds / unit.seconds))\(unit.suffix)"
        }
        return "now"
    }

    private static let ageSeconds: [String: Double] = [
        "second": 1, "sec": 1, "s": 1, "minute": 60, "min": 60, "m": 60, "hour": 3_600, "hr": 3_600, "h": 3_600,
        "day": 86_400, "d": 86_400, "week": 604_800, "wk": 604_800, "w": 604_800,
        "month": 2_592_000, "mo": 2_592_000, "year": 31_536_000, "yr": 31_536_000, "y": 31_536_000,
    ]

    // YouTube writes "6 minutes ago", "23h ago" or "Streamed 2 hours ago"; shorten those to match the
    // other sources' "6m". Other text, like "Live" or "Scheduled for…", stays as it is.
    // That text is as old as the fetch, so the age counts from `publishedAt` when there is one.
    private static func shortAge(_ published: String, publishedAt: Double?) -> String {
        guard let age = publishedAge(published) else { return published }
        let seconds = publishedAt.map { Date().timeIntervalSince1970 - $0 } ?? age.seconds
        return age.prefix + Self.age(seconds)
    }

    // The age in YouTube's text, and any "Streamed " or "Premiered " before it.
    private static func publishedAge(_ published: String) -> (prefix: String, seconds: Double)? {
        let pattern = /^(?<prefix>Streamed |Premiered )?(?<count>\d+)\s?(?<unit>second|sec|minute|min|hour|hr|day|week|wk|month|mo|year|yr|[smhdwy])s? ago$/
        guard let match = try? pattern.ignoresCase().wholeMatch(in: published.replacingOccurrences(of: "\u{a0}", with: " ")),
              let count = Double(match.count), let seconds = ageSeconds[match.unit.lowercased()] else { return nil }
        return (match.prefix.map { "\($0)" } ?? "", count * seconds)
    }
}

// AsyncImage forgets an image once its row scrolls away, so scrolling back shows the
// placeholder, refetches, and the row resizes when the image lands, jolting the list.
// This keeps decoded images in memory so returning rows draw at their final size at once.
@MainActor
enum ImageCache {
    static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    static func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let image = image(for: url) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return nil }
        // Decode off the main thread so the first display doesn't hitch the scroll.
        let image = await decoded.byPreparingForDisplay() ?? decoded
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        images.setObject(image, forKey: url as NSURL, cost: Int(pixels) * 4)
        return image
    }
}

struct CachedImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (Image?) -> Content
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        let image = loaded?.url == url ? loaded?.image : ImageCache.image(for: url)
        content(image.map { Image(uiImage: $0) })
            .task(id: url) {
                guard image == nil, let fetched = await ImageCache.load(url) else { return }
                loaded = (url, fetched)
            }
    }
}

// The All feed with every source turned off: a way to Settings to turn some on.
struct NoSourcesCard: View {
    @EnvironmentObject private var store: FeedStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No sources turned on")
                .font(.title3.bold())
            Text("Turn on Reddit, RSS or YouTube in Settings to fill your feed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                store.selectedTab = .settings
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                    Text("Open Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PostRow.cornerRadius))
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

extension View {
    // Blurs an NSFW image with a label over it; tapping it shows the image. Once shown,
    // taps go to the post as usual.
    func nsfwCover(hidden: Bool, compact: Bool = false, reveal: @escaping () -> Void) -> some View {
        blur(radius: hidden ? (compact ? 10 : 40) : 0, opaque: true)
            .overlay {
                if hidden {
                    ZStack {
                        Color.black.opacity(0.25)
                        if compact {
                            Text("NSFW")
                                .font(.caption2.weight(.bold))
                        } else {
                            Label("NSFW · Tap to show", systemImage: "eye.slash")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("NSFW image hidden")
                    .accessibilityHint("Shows the image")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { withAnimation(.easeOut(duration: 0.2)) { reveal() } },
                     including: hidden ? .all : .none)
    }
}
