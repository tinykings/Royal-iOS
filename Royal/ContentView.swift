import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = FeedStore()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    // The tabs in the order TabView lays them out, for mapping tab bar indexes back.
    private static let tabOrder: [AppTab] = [.reddit, .hn, .all, .youtube, .settings]

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
                RedditFeedView()
                    .tabItem { Image(uiImage: TabIcons.reddit).accessibilityLabel("Reddit") }
                    .tag(AppTab.reddit)
                HackerNewsFeedView()
                    .tabItem { Image(systemName: "y.square").accessibilityLabel("Hacker News") }
                    .tag(AppTab.hn)
                CombinedFeedView()
                    .tabItem {
                        Image(uiImage: TabIcons.crown)
                            .accessibilityLabel("All")
                    }
                    .tag(AppTab.all)
                FeedListView(title: "YouTube", tab: .youtube, keys: [.youtube])
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
            .background(TabReselect { index in
                if Self.tabOrder.indices.contains(index) { store.reselect(Self.tabOrder[index]) }
            })
            .frame(maxHeight: tabsHidden ? 0 : .infinity)
            .opacity(tabsHidden ? 0 : 1)
            .allowsHitTesting(!tabsHidden)
        }
        // Coming back after a while away brings feeds up to date.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshStale() } }
        }
        .tint(.royalAccent)
        .environmentObject(store)
    }
}

// The All page: every feed mixed together, or just the saved posts.
struct CombinedFeedView: View {
    @State private var showSaved = false

    var body: some View {
        FeedListView(title: "Royal", tab: .all, keys: FeedKey.combined, showsSource: true, savedOnly: showSaved,
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
        FeedListView(title: "Reddit", tab: .reddit, keys: [.reddit(sort: sort, timeframe: "day")], subtitle: sort.capitalized) {
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
        FeedListView(title: "Hacker News", tab: .hn, keys: [.hn(list: list)], subtitle: list.capitalized) {
            HeaderPicker(title: "List", selection: $list, options: [
                HeaderOption(value: "top", icon: "trophy", title: "Top"),
                HeaderOption(value: "new", icon: "clock", title: "New"),
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

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.filter.onReselect = onReselect
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
            return original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        @available(iOS 18, *)
        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === tabBarController.selectedTab {
                reselected(tabBarController)
                return false
            }
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
