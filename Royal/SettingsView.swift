import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var diagnostics = ""
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.list
    @AppStorage(Preference.youtubePlayback) private var youtubePlayback = VideoPlayback.inApp
    @AppStorage(Preference.listWhilePlaying) private var listWhilePlaying = false
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.list
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.hnOpen) private var hnOpen = OpenTarget.link

    private static let redditLogin = URL(string: "https://www.reddit.com/login/")!
    private static let youtubeLogin = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube"
        + "&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3D%252Ffeed%252Fsubscriptions")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LoginPage(title: "YouTube", url: Self.youtubeLogin)
                    } label: {
                        LabeledContent("Account", value: status(.youtube))
                    }
                    Picker("View", selection: $youtubeLayout) {
                        ForEach(FeedLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Play videos in", selection: $youtubePlayback) {
                        ForEach(VideoPlayback.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show list view when playing video", isOn: $listWhilePlaying)
                        .disabled(youtubePlayback != .inApp)
                } header: {
                    Text("YouTube")
                } footer: {
                    Text("Cards show a large thumbnail with the title below. With the in-app player, every section can switch to List view while a video plays.")
                }
                Section {
                    NavigationLink {
                        LoginPage(title: "Reddit", url: Self.redditLogin)
                    } label: {
                        LabeledContent("Account", value: status(.reddit))
                    }
                    Picker("View", selection: $redditLayout) {
                        ForEach(FeedLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Tapping a post opens", selection: $redditOpen) {
                        ForEach(OpenTarget.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Reddit")
                } footer: {
                    Text("Log in with a username and password; \"Continue with Google\" is blocked inside apps. Long-press a post to open the other.")
                }
                Section {
                    Picker("Tapping a post opens", selection: $hnOpen) {
                        ForEach(OpenTarget.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Hacker News")
                }
                Section("Diagnostics") {
                    Button("Run diagnostics") {
                        Task {
                            diagnostics = "Running…"
                            diagnostics = await store.diagnostics()
                        }
                    }
                    if !diagnostics.isEmpty {
                        Text(diagnostics)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Matches the feeds: no header while the docked video player is showing.
            .toolbar(store.playingVideo != nil ? .hidden : .visible, for: .navigationBar)
            // Runs again when returning from a login page.
            .onAppear { Task { await store.refreshLoginStatus() } }
        }
    }

    private func status(_ source: FeedSource) -> String {
        store.loggedIn[source] == true ? "Logged in" : "Not logged in"
    }
}

struct LoginPage: View {
    let title: String
    let url: URL

    var body: some View {
        WebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WebProfile.configuration())
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
