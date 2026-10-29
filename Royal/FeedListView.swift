import SafariServices
import SwiftUI
import WebKit

struct FeedListView<Trailing: View>: View {
    @EnvironmentObject private var store: FeedStore
    @Environment(\.openURL) private var openURL
    @State private var browserURL: BrowserURL?
    @State private var scrolledAway = false
    @State private var atTop = true
    // Refreshing because the tab was tapped again; there's no pull-to-refresh spinner then.
    @State private var tabRefreshing = false
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.cards
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.cards
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.hnOpen) private var hnOpen = OpenTarget.link
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
                    }
                    // The All feed opens with the time of its latest refresh, and puts posts
                    // new since the previous refresh above a divider.
                    let isAll = keys == FeedKey.combined && !savedOnly
                    let split = isAll ? store.splitByRefresh(posts) : nil
                    if isAll, let refresh = store.lastRefresh, !posts.isEmpty {
                        RefreshDivider(prefix: "Last refresh", date: refresh)
                    }
                    // Reaching any of the last rows fetches the next page.
                    let shown = split.map { $0.new + $0.seen } ?? posts
                    let endIDs = Set(shown.suffix(8).map(\.id))
                    if let split, let refresh = store.previousRefresh {
                        ForEach(split.new) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                        if !split.new.isEmpty && !split.seen.isEmpty {
                            RefreshDivider(prefix: "Previous refresh", date: refresh)
                        }
                        ForEach(split.seen) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                    } else {
                        ForEach(posts) { postRow($0, nearEnd: endIDs.contains($0.id)) }
                    }
                    if !savedOnly && !posts.isEmpty {
                        moreStatus
                    }
                }
                .listStyle(.plain)
                // Floats over the list; a row inserted at the top would sit just out of view.
                .overlay(alignment: .top) {
                    if tabRefreshing {
                        ProgressView()
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: tabRefreshing)
                // Lets the top anchor take no space; posts are taller than the default minimum.
                .environment(\.defaultMinListRowHeight, 0)
                // Posts sit on tiles over the grouped background.
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .hidesHeaderOnScroll($scrolledAway, atTop: $atTop)
                // Tapping the tab again scrolls to the top, or refreshes when already there.
                .onChange(of: store.reselected?.count) {
                    guard store.reselected?.tab == tab else { return }
                    if atTop {
                        guard !tabRefreshing else { return }
                        Task {
                            tabRefreshing = true
                            await store.load(keys, force: true)
                            tabRefreshing = false
                        }
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
                    if Trailing.self != EmptyView.self {
                        PlainToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: 8) {
                                Text(title)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                if let subtitle {
                                    Text(subtitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .fixedSize()
                        }
                        PlainToolbarItem(placement: .topBarTrailing) {
                            trailing
                        }
                    }
                }
                .refreshable { await store.load(keys, force: true) }
                .task(id: keys) { await store.load(keys) }
                .fullScreenCover(item: $browserURL) { item in
                    if item.loggedIn {
                        AppBrowser(url: item.url)
                    } else {
                        SafariView(url: item.url)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }

    private static var topID: String { "top" }

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
        return PostRow(post: post, showsSource: showsSource, layout: layout(for: post), saved: isSaved,
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
            browserURL = BrowserURL(url: url, loggedIn: reddit)
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

struct BrowserURL: Identifiable {
    let url: URL
    // Open in AppBrowser, which shares the app's logins, instead of the Safari view.
    var loggedIn = false
    var id: String { url.absoluteString }
}

// A browser on the app's web profile, so pages see the logins made in the app.
struct AppBrowser: View {
    let url: URL
    @StateObject private var page = BrowserPage()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let current = page.url ?? url
        NavigationStack {
            BrowserWebView(url: url, page: page)
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

private struct BrowserWebView: UIViewRepresentable {
    let url: URL
    let page: BrowserPage

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebProfile.configuration())
        webView.allowsBackForwardNavigationGestures = true
        page.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            dismiss()
        }
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

// Shows a refresh time in the All feed: atop it, and where the previous refresh's posts begin.
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
        let time = date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                  time: .shortened)
        return "\(prefix) · \(time)"
    }
}

struct PostRow: View {
    let post: FeedPost
    var showsSource = false
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
                    // screen; narrow ones sit on a faint backdrop across the tile. The frame
                    // comes from Reddit's reported size, not the loaded image, so the tile
                    // doesn't change height when the image arrives; a list that resizes rows
                    // as you scroll back up jumps around.
                    Color.secondary.opacity(0.08)
                        .aspectRatio(max(post.imageAspect ?? 4 / 3, Self.tallestImageAspect), contentMode: .fit)
                        .overlay {
                            CachedImage(url: thumbnail) { image in
                                image?.resizable().scaledToFit()
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
        if let created = post.created { parts.append(Self.age(Date().timeIntervalSince1970 - created)) }
        if let published = post.published, !published.isEmpty { parts.append(Self.shortAge(published)) }
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
    private static func shortAge(_ published: String) -> String {
        let pattern = /^(?<prefix>Streamed |Premiered )?(?<count>\d+)\s?(?<unit>second|sec|minute|min|hour|hr|day|week|wk|month|mo|year|yr|[smhdwy])s? ago$/
        guard let match = try? pattern.ignoresCase().wholeMatch(in: published.replacingOccurrences(of: "\u{a0}", with: " ")),
              let count = Double(match.count), let seconds = ageSeconds[match.unit.lowercased()] else { return published }
        return (match.prefix.map { "\($0)" } ?? "") + age(count * seconds)
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
