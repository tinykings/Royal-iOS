import SwiftUI

struct ContentView: View {
    @StateObject private var store = FeedStore()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // Landscape has no room for feeds under the video, so it plays full screen.
        let expanded = verticalSizeClass == .compact
        let tabsHidden = expanded && store.playingVideo != nil
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let post = store.playingVideo {
                    VideoPanel(post: post, expanded: expanded, collapsedHeight: geometry.size.width * 9 / 16)
                        .id(post.id)
                }
                // Hidden rather than removed so each tab keeps its scroll position.
                // All opens first. Tabs are icons only; labels are for VoiceOver.
                TabView(selection: $store.selectedTab) {
                    RedditFeedView()
                        .tabItem { Image(uiImage: TabIcons.reddit).accessibilityLabel("Reddit") }
                        .tag(AppTab.reddit)
                    HackerNewsFeedView()
                        .tabItem { Image(systemName: "y.square").accessibilityLabel("Hacker News") }
                        .tag(AppTab.hn)
                    CombinedFeedView()
                        .tabItem {
                            Image(uiImage: TabIcons.crown(selected: store.selectedTab == .all)).accessibilityLabel("All")
                        }
                        .tag(AppTab.all)
                    FeedListView(title: "YouTube", keys: [.youtube])
                        .tabItem { Image(systemName: "play.rectangle").accessibilityLabel("YouTube") }
                        .tag(AppTab.youtube)
                    SettingsView()
                        .tabItem { Image(systemName: "gearshape").accessibilityLabel("Settings") }
                        .tag(AppTab.settings)
                }
                // After visiting Settings (possibly to log in), retry feeds that failed.
                .onChange(of: store.selectedTab) { oldTab, _ in
                    if oldTab == .settings { Task { await store.reloadFailed() } }
                }
                .frame(maxHeight: tabsHidden ? 0 : .infinity)
                .opacity(tabsHidden ? 0 : 1)
                .allowsHitTesting(!tabsHidden)
            }
        }
        .environmentObject(store)
    }
}

// The All page: every feed mixed together, or just the saved posts.
struct CombinedFeedView: View {
    @State private var showSaved = false

    var body: some View {
        FeedListView(title: "Royal", keys: FeedKey.combined, showsSource: true, savedOnly: showSaved,
                     subtitle: showSaved ? "Saved" : "All") {
            HeaderPicker(title: "Show", selection: $showSaved, options: [
                HeaderOption(value: false, icon: "square.stack", title: "All"),
                HeaderOption(value: true, icon: "heart", title: "Saved"),
            ])
        }
    }
}

struct RedditFeedView: View {
    @State private var sort = "best"

    var body: some View {
        // Top is always today's, so Best uses the same feed as the All page.
        FeedListView(title: "Reddit", keys: [.reddit(sort: sort, timeframe: "day")], subtitle: sort.capitalized) {
            HeaderPicker(title: "Sort", selection: $sort, options: [
                HeaderOption(value: "best", icon: "rosette", title: "Best"),
                HeaderOption(value: "top", icon: "trophy", title: "Top"),
                HeaderOption(value: "new", icon: "clock", title: "New"),
            ])
        }
    }
}

struct HackerNewsFeedView: View {
    @State private var list = "top"

    var body: some View {
        FeedListView(title: "Hacker News", keys: [.hn(list: list)], subtitle: list.capitalized) {
            HeaderPicker(title: "List", selection: $list, options: [
                HeaderOption(value: "top", icon: "trophy", title: "Top"),
                HeaderOption(value: "new", icon: "clock", title: "New"),
            ])
        }
    }
}
