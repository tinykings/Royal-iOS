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
                // All opens first.
                TabView(selection: $store.selectedTab) {
                    HackerNewsFeedView()
                        .tabItem { Label("Hacker News", systemImage: "y.square") }
                        .tag(AppTab.hn)
                    RedditFeedView()
                        .tabItem { Label { Text("Reddit") } icon: { Image(uiImage: TabIcons.reddit) } }
                        .tag(AppTab.reddit)
                    CombinedFeedView()
                        .tabItem {
                            Label { Text("All") } icon: { Image(uiImage: TabIcons.crown(selected: store.selectedTab == .all)) }
                        }
                        .tag(AppTab.all)
                    FeedListView(title: "YouTube", keys: [.youtube])
                        .tabItem { Label("YouTube", systemImage: "play.rectangle") }
                        .tag(AppTab.youtube)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
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
            IconSegments {
                IconSegment(icon: "square.stack", title: "All", selected: !showSaved) { showSaved = false }
                IconSegment(icon: "heart", title: "Saved", selected: showSaved) { showSaved = true }
            }
        }
    }
}

struct RedditFeedView: View {
    @State private var sort = "best"
    @State private var timeframe = RedditTimeframe.day

    var body: some View {
        FeedListView(title: "Reddit", keys: [.reddit(sort: sort, timeframe: timeframe.rawValue)],
                     subtitle: sort == "top" ? "Top · \(timeframe.title)" : sort.capitalized) {
            IconSegments {
                IconSegment(icon: "rosette", title: "Best", selected: sort == "best") { sort = "best" }
                // Top asks for a timeframe first.
                Menu {
                    ForEach(RedditTimeframe.allCases) { option in
                        Button {
                            timeframe = option
                            sort = "top"
                        } label: {
                            if sort == "top" && timeframe == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    IconSegmentLabel(icon: "trophy", title: "Top", selected: sort == "top")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                IconSegment(icon: "clock", title: "New", selected: sort == "new") { sort = "new" }
            }
        }
    }
}

struct HackerNewsFeedView: View {
    @State private var list = "top"

    var body: some View {
        FeedListView(title: "Hacker News", keys: [.hn(list: list)], subtitle: list.capitalized) {
            IconSegments {
                IconSegment(icon: "trophy", title: "Top", selected: list == "top") { list = "top" }
                IconSegment(icon: "clock", title: "New", selected: list == "new") { list = "new" }
            }
        }
    }
}
