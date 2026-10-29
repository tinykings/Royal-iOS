import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var diagnostics = ""
    @State private var confirmingLogOut: FeedSource?
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
                            .feedTextSize(feedTextSize)
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
                    Text("Sets the size of post text in every feed. Default follows the text size in the Settings app.")
                }
                Section {
                    NavigationLink {
                        LoginPage(title: "YouTube", url: FeedSource.youtube.loginURL!)
                    } label: {
                        LabeledContent("Account", value: status(.youtube))
                    }
                    logOutButton(.youtube)
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
                    Text("Cards show a large thumbnail with the title below. With the in-app player, every section can switch to List view while a video plays. YouTube feeds rely on undocumented page data and may break when YouTube changes its site.")
                }
                Section {
                    NavigationLink {
                        LoginPage(title: "Reddit", url: FeedSource.reddit.loginURL!)
                    } label: {
                        LabeledContent("Account", value: status(.reddit))
                    }
                    logOutButton(.reddit)
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
                Section {
                    LabeledContent("Version", value: appVersion)
                    Link(destination: URL(string: "https://github.com/tinykings/Royal-iOS")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Royal has no server. It talks directly to Reddit, Hacker News, and YouTube with your logins, and collects nothing.")
                }
                #if DEBUG
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
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Runs again when returning from a login page.
            .onAppear { Task { await store.refreshLoginStatus() } }
            .confirmationDialog(confirmingLogOut.map { "Log out of \($0.title)?" } ?? "",
                                isPresented: Binding { confirmingLogOut != nil } set: { if !$0 { confirmingLogOut = nil } },
                                titleVisibility: .visible, presenting: confirmingLogOut) { source in
                Button("Log Out", role: .destructive) {
                    Task { await store.logOut(source) }
                }
            } message: { source in
                Text(source == .youtube
                     ? "Your \(source.title) feed will be empty until you log in again. This also signs out of Google in the app."
                     : "Your \(source.title) feed will be empty until you log in again.")
            }
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

    // "0.1 (1)": marketing version and build number.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private func logOutButton(_ source: FeedSource) -> some View {
        if store.loggedIn[source] == true {
            Button("Log Out", role: .destructive) { confirmingLogOut = source }
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
