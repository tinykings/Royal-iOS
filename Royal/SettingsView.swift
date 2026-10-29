import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var diagnostics = ""
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.cards
    @AppStorage(Preference.youtubePlayback) private var youtubePlayback = VideoPlayback.inApp
    @AppStorage(Preference.listWhilePlaying) private var listWhilePlaying = true
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.cards
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.hnOpen) private var hnOpen = OpenTarget.link
    @AppStorage(Preference.feedTextSize) private var feedTextSize = FeedTextSize.standard

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                                .accessibilityHidden(true)
                            Slider(value: textSizeStep, in: 0...Double(FeedTextSize.allCases.count - 1), step: 1) {
                                Text("Text size")
                            }
                            .accessibilityValue(feedTextSize.title)
                            Image(systemName: "textformat.size.larger")
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        // Live sample at the chosen size.
                        Text("The quick brown fox jumps over the lazy dog")
                            .font(.body)
                            .dynamicTypeSize(feedTextSize.dynamicTypeSize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text(feedTextSize.title)
                    }
                } footer: {
                    Text("Sets the size of post text in every feed.")
                }
                Section {
                    NavigationLink {
                        LoginPage(title: "YouTube", url: FeedSource.youtube.loginURL!)
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
                        LoginPage(title: "Reddit", url: FeedSource.reddit.loginURL!)
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

    // The slider works in Doubles; snap to a FeedTextSize step.
    private var textSizeStep: Binding<Double> {
        Binding {
            Double(feedTextSize.rawValue)
        } set: {
            feedTextSize = FeedTextSize(rawValue: Int($0.rounded())) ?? .standard
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
