import SafariServices
import SwiftUI
import WebKit

struct FeedListView<Trailing: View>: View {
    @EnvironmentObject private var store: FeedStore
    @Environment(\.openURL) private var openURL
    @State private var browserURL: BrowserURL?
    @State private var scrolledAway = false
    @State private var atTop = true
    // A refresh asked for by pulling the feed down or tapping its tab again; its status
    // shows in the header until a moment after it's done.
    @State private var refresh: RefreshRun?
    // The All feed shows just its unread posts until this is set.
    @State private var showEarlier = false
    // How far past the end the feed is pulled up, to mark it read or show earlier posts.
    @State private var pullUp: CGFloat = 0
    // How far past the top the feed is pulled down, to refresh.
    @State private var pullDown: CGFloat = 0
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.cards
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.cards
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.hnOpen) private var hnOpen = OpenTarget.link
    @AppStorage(Preference.youtubePlayback) private var youtubePlayback = VideoPlayback.inApp
    @AppStorage(Preference.listWhilePlaying) private var listWhilePlaying = true
    @AppStorage(Preference.redditNSFW) private var showsNSFW = false
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
    // Optional nav bar control; when present the title moves to the leading edge.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // NSFW posts hide here too, so turning the setting off takes effect at once, saved
        // posts included, without waiting on a reload.
        let posts = (savedOnly ? store.savedPosts : store.posts(keys)).filter { showsNSFW || $0.nsfw != true }
        // The header slides away while scrolling down, leaving more room for the feed,
        // and comes back on scrolling up, so its controls stay in reach during a video.
        let headerHidden = scrolledAway
        // Feeds needing an account start with a card for logging in, in place of their errors.
        let loggedOut = savedOnly ? [] : [FeedSource.reddit, .youtube].filter { source in
            keys.contains { $0.source == source } && store.loggedIn[source] == false
        }
        // The All feed opens with the time of its latest refresh, and puts posts
        // new since the previous refresh first.
        let isAll = keys == FeedKey.combined && !savedOnly
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
                    if !loggedOut.isEmpty {
                        LoginCard(sources: loggedOut, keys: keys)
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
                                    if key.source != .hn {
                                        Button("Settings") { store.selectedTab = .settings }
                                            .font(.footnote)
                                    }
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
                    } else if posts.isEmpty && loggedOut.isEmpty
                                && keys.allSatisfy({ store.state($0).loaded && !store.state($0).loading && store.state($0).error == nil }) {
                        // A quiet subreddit can have nothing in Top today.
                        Text("No posts to show.")
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
                                MarkReadButton(pullable: Self.canPull) { markRead(proxy) }
                            } else {
                                EarlierPostsButton(date: store.previousRefresh, pullable: Self.canPull) {
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
                .background(Color(.systemGroupedBackground))
                .hidesHeaderOnScroll($scrolledAway, atTop: $atTop)
                // Pulling up past the unread posts marks them read, and pulling up the empty
                // feed then shows the earlier ones, like pulling down refreshes.
                .pullPast(.bottom, enabled: collapsed, distance: $pullUp, threshold: Self.pullThreshold,
                          settleFirst: true) {
                    if hasUnread {
                        markRead(proxy)
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
                // Pulling down past the top refreshes, with the header saying so in place of the
                // system spinner. Only a drag counts, so the bounce after a fling leaves it alone.
                .pullPast(.top, enabled: refresh?.finished != false, distance: $pullDown,
                          threshold: Self.pullThreshold, whileDragging: true) {
                    Task { await refreshFeeds() }
                }
                // Tapping the tab again scrolls to the top, or refreshes when already there.
                .onChange(of: store.reselected?.count) {
                    guard store.reselected?.tab == tab else { return }
                    if atTop {
                        guard refresh?.finished != false else { return }
                        Task { await refreshFeeds() }
                    } else {
                        withAnimation { proxy.scrollTo(Self.topID, anchor: .top) }
                        scrolledAway = false
                    }
                }
                .toolbar(headerHidden ? .hidden : .visible, for: .navigationBar)
                .animation(.easeInOut(duration: 0.2), value: headerHidden)
                .navigationTitle(Trailing.self == EmptyView.self ? title : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // A pull takes over the whole header.
                    if pullDown > 0 {
                        PlainToolbarItem(placement: .principal) {
                            PullDownHeader(distance: pullDown, threshold: Self.pullThreshold)
                        }
                    }
                    if pullDown == 0 && Trailing.self != EmptyView.self {
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
                    if pullDown == 0 && Trailing.self == EmptyView.self {
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
                .task(id: keys) { await store.load(keys) }
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
        await store.load(keys, force: true)
        guard refresh?.id == run.id else { return }
        refresh?.finished = true
        // Leaves the results up long enough to pass through them all, unless another
        // refresh has begun since.
        let linger = max(3, Double(keys.count) * RefreshStatus.interval)
        Task {
            try? await Task.sleep(for: .seconds(linger))
            if refresh?.id == run.id { refresh = nil }
        }
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
            }
            // Swiping right offers what a tap doesn't, per Settings.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                alternateActions(for: post)
            }
            .contextMenu {
                saveButton(for: post, isSaved: isSaved)
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
        case .hn: return .list
        }
    }

    private func saveButton(for post: FeedPost, isSaved: Bool) -> some View {
        Button {
            withAnimation { store.toggleSaved(post) }
        } label: {
            Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "heart.slash" : "heart")
        }
    }

    // The open options a tap doesn't use: the other of link/comments, or the other
    // two places to play a video.
    @ViewBuilder
    private func alternateActions(for post: FeedPost) -> some View {
        if post.source == .youtube {
            ForEach(VideoPlayback.allCases.filter { $0 != youtubePlayback }) { playback in
                Button {
                    play(post, with: playback)
                } label: {
                    Label(playback == .inApp ? "Play in app" : "Open in \(playback.title)", systemImage: playback.icon)
                }
                .tint(playback == .youtubeApp ? .red : .blue)
            }
        } else if openTarget(for: post) == .comments {
            Button { openInBrowser(post.url) } label: { Label("Open link", systemImage: "link") }
                .tint(.blue)
        } else {
            Button { openInBrowser(post.commentsUrl) } label: { Label("Open comments", systemImage: "bubble.left.and.bubble.right") }
                .tint(.blue)
        }
    }

    private func openTarget(for post: FeedPost) -> OpenTarget {
        post.source == .hn ? hnOpen : redditOpen
    }

    // Videos play where Settings says; Reddit and Hacker News open their link or
    // comments, per Settings, in the in-app browser.
    private func open(_ post: FeedPost) {
        if post.source == .youtube {
            play(post, with: youtubePlayback)
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
    // the top; `atTop` says whether the list is scrolled to the top. Needs iOS 18 scroll
    // geometry; earlier versions keep the header and report not being at the top.
    @ViewBuilder
    func hidesHeaderOnScroll(_ hidden: Binding<Bool>, atTop: Binding<Bool>) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: ScrollPosition.self) { geometry in
                ScrollPosition(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                               maxOffset: geometry.contentSize.height - geometry.containerSize.height
                                   + geometry.contentInsets.top + geometry.contentInsets.bottom,
                               insetTop: geometry.contentInsets.top)
            } action: { old, new in
                atTop.wrappedValue = new.offset <= 1
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
            onAppear { atTop.wrappedValue = false }
        }
    }
}

extension View {
    // Sets `distance` to how far the list is dragged past its top or end, and calls
    // `action` when let go past `threshold`. The list's own bounce gives the pull its
    // resistance. With `settleFirst` the action waits for the bounce back to settle, which
    // would otherwise carry the list on past where the action scrolls it to. With
    // `whileDragging` the distance only counts during a drag, and is 0 once let go. Needs
    // iOS 18 scroll geometry.
    @ViewBuilder
    func pullPast(_ edge: VerticalEdge, enabled: Bool, distance: Binding<CGFloat>, threshold: CGFloat,
                  settleFirst: Bool = false, whileDragging: Bool = false,
                  action: @escaping () -> Void) -> some View {
        if #available(iOS 18, *) {
            modifier(PullPastEdge(edge: edge, enabled: enabled, distance: distance, threshold: threshold,
                                  settleFirst: settleFirst, whileDragging: whileDragging, action: action))
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
struct LoginCard: View {
    @EnvironmentObject private var store: FeedStore
    @State private var loggingIn: FeedSource?
    let sources: [FeedSource]
    // The feeds to reload once logged in.
    let keys: [FeedKey]
    // The All feed, which mixes in Hacker News.
    private var combined: Bool { keys == FeedKey.combined }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(combined ? "Log in to see your feeds" : "Log in to \(sources[0].title)")
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

    private var message: String {
        let reddit = "For Reddit, use a username and password; \"Continue with Google\" is blocked inside apps. "
        // Closing the page is what checks the login and reloads the feed.
        let done = "Once you're logged in, tap Done."
        if combined {
            let names = sources.map(\.title).joined(separator: " and ")
            return "Log in to \(names) to see your subscriptions here alongside Hacker News. "
                + (sources.contains(.reddit) ? reddit : "") + done
        }
        return sources[0] == .reddit
            ? "Log in to see your Reddit home feed. " + reddit + done
            : "Log in to see videos from your YouTube subscriptions. " + done
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
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// Fills the All feed once nothing's unread; tapping it shows the posts from earlier refreshes.
struct EarlierPostsButton: View {
    // Where the earlier posts leave off.
    let date: Date?
    // The feed shows the earlier posts when pulled up past here, so this is just a hint;
    // VoiceOver still offers it as a button.
    var pullable = false
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
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// Fills the header while the feed is pulled down; letting go once it says so refreshes.
struct PullDownHeader: View {
    let distance: CGFloat
    let threshold: CGFloat

    private var armed: Bool { distance >= threshold }

    var body: some View {
        Text(armed ? "Release to refresh" : "Pull down to refresh")
            .font(.headline)
            .foregroundStyle(armed ? Color.royalAccent : Color.primary)
            .fixedSize()
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, armed in armed }
    }
}

// Comes in from the bottom as the feed is pulled up past its end: the horse fills with gold
// from the bottom up, and once full, letting go does what the caption says.
struct PullIndicator: View {
    let prompt: String
    let release: String
    let distance: CGFloat
    let threshold: CGFloat

    static func markRead(distance: CGFloat, threshold: CGFloat) -> PullIndicator {
        PullIndicator(prompt: "Pull up to mark as read", release: "Release to mark as read",
                      distance: distance, threshold: threshold)
    }

    static func earlier(distance: CGFloat, threshold: CGFloat) -> PullIndicator {
        PullIndicator(prompt: "Pull up for earlier posts", release: "Release for earlier posts",
                      distance: distance, threshold: threshold)
    }

    // The art's width over its height.
    private static let aspect: CGFloat = 360 / 315
    private static let width: CGFloat = 80
    private var height: CGFloat { Self.width / Self.aspect }

    private var progress: CGFloat { min(distance / threshold, 1) }
    private var armed: Bool { distance >= threshold }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                art
                    .opacity(0.8)
                // The art is light gray, so multiplying keeps its shading and lines in gold.
                art
                    .colorMultiply(.royalAccent)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: height * progress)
                    }
            }
            .frame(width: Self.width, height: height)
            .scaleEffect(armed ? 1.15 : 0.7 + 0.3 * progress)
            Text(armed ? release : prompt)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        // Clears the floating tab bar, which the list runs under.
        .padding(.bottom, 44)
        .opacity(Double(progress))
        // Comes in with the gap the pull opens, rather than ahead of it.
        .offset(y: max(0, threshold - distance) * 0.6)
        .animation(.spring(duration: 0.25), value: armed)
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, armed in armed }
    }

    private var art: some View {
        Image("PullHorse")
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
                    // Reddit images keep their own shape, capped so tall ones don't fill the
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
        case .hn: "y.square.fill"
        case .youtube: "play.rectangle.fill"
        }
    }

    private var color: Color {
        switch post.source {
        case .reddit: .orange
        case .hn: .brown
        case .youtube: .red
        }
    }

    private var thumbnail: URL? {
        // hqdefault exists for every video; larger sizes can be missing.
        if let videoId = post.videoId { return URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg") }
        return post.image.flatMap(URL.init(string:))
    }

    private var meta: String {
        var parts = [post.label]
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
