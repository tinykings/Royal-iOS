import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = FeedStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    // The tabs in the order TabView lays them out, for mapping tab bar indexes back.
    private static let tabOrder: [AppTab] = [.rss, .reddit, .all, .youtube, .settings]

    var body: some View {
        // Landscape has no room for feeds under the video, so it plays full screen.
        let expanded = verticalSizeClass == .compact
        let tabsHidden = expanded && store.playingVideo != nil
        VStack(spacing: 0) {
            if let post = store.playingVideo {
                VideoPanel(post: post, expanded: expanded)
                    .id(post.id)
            }
            // Hidden rather than removed so each tab keeps its scroll position.
            // All opens first. Tabs are icons only; labels are for VoiceOver.
            TabView(selection: $store.selectedTab) {
                sourceTab(.rss, icon: Image(uiImage: TabIcons.rss)) { RSSFeedView() }
                    .tag(AppTab.rss)
                sourceTab(.reddit, icon: Image(uiImage: TabIcons.reddit)) { RedditFeedView() }
                    .tag(AppTab.reddit)
                CombinedFeedView()
                    .tabItem {
                        Image(uiImage: TabIcons.crown)
                            .accessibilityLabel("All")
                    }
                    .tag(AppTab.all)
                sourceTab(.youtube, icon: Image(systemName: "play.rectangle")) { YouTubeFeedView() }
                    .tag(AppTab.youtube)
                SettingsView()
                    .tabItem { Image(uiImage: TabIcons.settings).accessibilityLabel("Settings") }
                    .tag(AppTab.settings)
            }
            // After visiting Settings (possibly to log in), retry feeds that failed.
            .onChange(of: store.selectedTab) { oldTab, _ in
                if oldTab == .settings { Task { await store.reloadFailed() } }
            }
            .background(TabReselect(onReselect: { index in
                if Self.tabOrder.indices.contains(index) { store.reselect(Self.tabOrder[index]) }
            }, isBlocked: { index in
                // A turned-off source's dot can't be picked.
                Self.tabOrder.indices.contains(index) && Self.tabOrder[index].source.map { !store.isEnabled($0) } == true
            }))
            .frame(maxHeight: tabsHidden ? 0 : .infinity)
            .opacity(tabsHidden ? 0 : 1)
            .allowsHitTesting(!tabsHidden)
        }
        // Feeds open as they were left, so check logins apart from loading them.
        .task { await store.refreshLoginStatus() }
        // Saved-post sync has no background timer; it catches up here.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.savedSync.scheduleSync(after: 0) }
        }
        .tint(.royalAccent)
        .environmentObject(store)
    }

    // A source's tab. Turned off in Settings, it keeps its place in the tab bar as a dot
    // that can't be picked, and its feed isn't loaded.
    @ViewBuilder
    private func sourceTab<Feed: View>(_ source: FeedSource, icon: Image, @ViewBuilder feed: () -> Feed) -> some View {
        if store.isEnabled(source) {
            feed().tabItem { icon.accessibilityLabel(source.title) }
        } else {
            Color.clear.tabItem { Image(uiImage: TabIcons.dot).accessibilityLabel("\(source.title), turned off") }
        }
    }
}

extension AppTab {
    // The source a tab shows on its own, if any.
    var source: FeedSource? {
        switch self {
        case .reddit: .reddit
        case .rss: .rss
        case .youtube: .youtube
        case .all, .settings: nil
        }
    }
}

// The All page: every feed mixed together, or just the saved posts.
struct CombinedFeedView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var showSaved = false

    var body: some View {
        FeedListView(title: "Royal", tab: .all, keys: store.combinedKeys, showsSource: true, savedOnly: showSaved,
                     subtitle: showSaved ? "Saved" : "All",
                     onNothingNew: { withAnimation { showSaved = true } }) {
            HeaderPicker(title: "Show", selection: $showSaved, options: [
                HeaderOption(value: false, icon: "square.stack", title: "All"),
                HeaderOption(value: true, icon: "heart", title: "Saved",
                             selectedIcon: "heart.fill", selectedColor: .systemPink),
            ])
        }
        // Tapping the crown tab again on Saved goes back to All.
        .onChange(of: store.reselected?.count) {
            guard store.reselected?.tab == .all, showSaved else { return }
            withAnimation { showSaved = false }
        }
    }
}

struct RedditFeedView: View {
    // Starts on Best and stays on whichever sort was picked last.
    @AppStorage(Preference.redditSort) private var sort = "best"
    @EnvironmentObject private var store: FeedStore
    // The one subreddit showing, or nil for everything followed. Starts on everything.
    @State private var subreddit: String?

    var body: some View {
        // Top is always today's, so it uses the same feed as the All page. A single subreddit
        // only has Top, since Reddit refuses its Hot and New; the sort picked for everything
        // followed is kept for coming back.
        let key: FeedKey = subreddit.map { FeedKey.subreddit(name: $0) }
            ?? .reddit(sort: sort, timeframe: "day")
        FeedListView(title: "Reddit", tab: .reddit, keys: [key],
                     // A subreddit's name takes up the room the sort's name would use.
                     subtitle: subreddit != nil ? nil : sort == "top" ? "Top Today" : sort.capitalized,
                     titleMenu: AnyView(subredditMenu)) {
            if subreddit == nil {
                HeaderPicker(title: "Sort", selection: $sort, options: [
                    HeaderOption(value: "best", icon: "rosette", title: "Best"),
                    HeaderOption(value: "top", icon: "trophy", title: "Top"),
                ])
            }
        }
        .task { if store.subreddits.isEmpty { await store.loadSubreddits() } }
        // Back to everything if the subreddit leaves the list, as one unfollowed elsewhere does.
        .onChange(of: store.subreddits) { _, names in
            if let subreddit, !names.contains(subreddit) { self.subreddit = nil }
        }
    }

    private var subredditMenu: some View {
        Menu {
            Picker("Subreddit", selection: $subreddit) {
                Text("All Subreddits").tag(String?.none)
                ForEach(store.subreddits, id: \.self) { name in
                    Text("r/\(name)").tag(String?.some(name))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(subredditTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(subreddit.map { "Subreddit: \($0)" } ?? "Reddit, all subreddits")
    }

    // Shortened by hand since the header sizes its title to fit.
    private var subredditTitle: String {
        guard let subreddit else { return "All Subreddits" }
        return "r/" + (subreddit.count > 14 ? String(subreddit.prefix(13)) + "…" : subreddit)
    }
}

struct RSSFeedView: View {
    @EnvironmentObject private var store: FeedStore

    var body: some View {
        let count = store.rssFeeds.count
        FeedListView(title: "RSS", tab: .rss, keys: [.rss], subtitle: count == 1 ? "1 Feed" : "\(count) Feeds",
                     emptyText: store.rssFeeds.isEmpty ? "No feeds yet. Tap the list button to add one." : nil) {
            // The feed list from Settings, opened over the feed.
            NavigationLink {
                RSSFeedsView()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Manage Feeds")
        }
    }
}

struct YouTubeFeedView: View {
    @State private var key = FeedKey.youtube

    var body: some View {
        FeedListView(title: "YouTube", tab: .youtube, keys: [key],
                     subtitle: key == .youtube ? "Subscriptions" : "Recommended") {
            HeaderPicker(title: "Show", selection: $key, options: [
                HeaderOption(value: FeedKey.youtube, icon: "play.square.stack", title: "Subscriptions"),
                HeaderOption(value: FeedKey.youtubeHome, icon: "house", title: "Recommended"),
            ])
        }
    }
}

// Tapping the tab that's already showing would nudge its feed partway toward the top.
// SwiftUI has no setting for this, so wrap the tab bar controller's delegate to turn
// those taps down and report them instead, passing everything else on to SwiftUI's
// own delegate. The feeds then scroll to the top themselves.
private struct TabReselect: UIViewControllerRepresentable {
    // Called with the index of the tab tapped again.
    let onReselect: (Int) -> Void
    // Whether the tab at an index is turned off and can't be selected.
    let isBlocked: (Int) -> Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.filter.onReselect = onReselect
        controller.filter.isBlocked = isBlocked
    }

    final class Controller: UIViewController {
        let filter = ReselectFilter()

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // SwiftUI can set its delegate again after an update; put the filter back in front.
            install()
        }

        private func install() {
            guard let tabs = view.window?.rootViewController.flatMap(Self.tabBarController(in:)),
                  tabs.delegate !== filter else { return }
            filter.original = tabs.delegate
            tabs.delegate = filter
        }

        private static func tabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children + [controller.presentedViewController].compactMap({ $0 }) {
                if let tabs = tabBarController(in: child) { return tabs }
            }
            return nil
        }
    }

    final class ReselectFilter: NSObject, UITabBarControllerDelegate {
        weak var original: UITabBarControllerDelegate?
        var onReselect: ((Int) -> Void)?
        var isBlocked: ((Int) -> Bool)?
        // Both delegate methods can be asked about one tap; report it once.
        private var lastReport = Date.distantPast

        private func reselected(_ tabBarController: UITabBarController) {
            guard Date().timeIntervalSince(lastReport) > 0.3 else { return }
            lastReport = Date()
            onReselect?(tabBarController.selectedIndex)
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if viewController === tabBarController.selectedViewController {
                reselected(tabBarController)
                return false
            }
            if let index = tabBarController.viewControllers?.firstIndex(of: viewController),
               isBlocked?(index) == true { return false }
            return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        @available(iOS 18, *)
        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === tabBarController.selectedTab {
                reselected(tabBarController)
                return false
            }
            if let index = tabBarController.tabs.firstIndex(of: tab), isBlocked?(index) == true { return false }
            return original?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}
