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
    @AppStorage(Preference.rssOpen) private var rssOpen = RSSOpenTarget.description
    @AppStorage(Preference.rssLayout) private var rssLayout = FeedLayout.cards
    @AppStorage(Preference.feedTextSize) private var feedTextSize = FeedTextSize.standard

    var body: some View {
        NavigationStack {
            List {
                // The app's crown, its website, and its version, centered above everything else.
                Section {
                    VStack(spacing: 10) {
                        RoyalCrown()
                            .fill(Color.royalAccent)
                            .frame(width: 72, height: 72 / RoyalCrown.aspectRatio)
                            .accessibilityHidden(true)
                        Link("royal.tinyk.ing", destination: URL(string: "https://royal.tinyk.ing")!)
                            .font(.subheadline.weight(.medium))
                        Text("Version \(appVersion)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
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
                    ForEach(FeedSource.allCases) { source in
                        Toggle(source.title, isOn: Binding {
                            store.isEnabled(source)
                        } set: {
                            store.setEnabled(source, $0)
                        })
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("A source turned off leaves the All feed, and its tab becomes a dot.")
                }
                // Shown only while the source is on.
                if store.isEnabled(.youtube) {
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
                }
                // Shown only while the source is on.
                if store.isEnabled(.reddit) {
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
                        Text("Log in with a username and password; \"Continue with Google\" is blocked inside apps. Long-press a post to open the other. NSFW posts are left out.")
                    }
                }
                // Shown only while the source is on.
                if store.isEnabled(.rss) {
                    Section {
                        NavigationLink {
                            RSSFeedsView()
                        } label: {
                            LabeledContent("Feeds", value: "\(store.rssFeeds.count)")
                        }
                        Picker("View", selection: $rssLayout) {
                            ForEach(FeedLayout.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Tapping a post opens", selection: $rssOpen) {
                            ForEach(RSSOpenTarget.allCases) { Text($0.title).tag($0) }
                        }
                    } header: {
                        Text("RSS")
                    } footer: {
                        Text("Add, remove, import or export feeds under Feeds. Swipe right on a post, or press and hold it, to open the other.")
                    }
                }
                SyncSection(sync: store.savedSync)
                #if DEBUG
                Section("Diagnostics") {
                    Button("Run diagnostics") {
                        Task {
                            diagnostics = "Running…"
                            diagnostics = await store.diagnostics()
                        }
                    }
                    cookieExpirations(.youtube)
                    cookieExpirations(.reddit)
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

    // When each login cookie runs out, as set by the service and capped by WebKit.
    // Shown under Diagnostics, so each row names its service.
    @ViewBuilder
    private func cookieExpirations(_ source: FeedSource) -> some View {
        if store.loggedIn[source] == true {
            ForEach(store.loginCookies[source] ?? []) { cookie in
                LabeledContent {
                    Text(expiration(cookie))
                } label: {
                    Text("\(source.title): \(cookie.kind)")
                    Text(cookie.name)
                        .font(.caption.monospaced())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(source.title): \(cookie.kind), \(expiration(cookie))")
            }
        }
    }

    private func expiration(_ cookie: LoginCookie) -> String {
        guard let expires = cookie.expires else { return "Until app closes" }
        return expires > Date() ? "Expires \(expires.formatted(date: .abbreviated, time: .omitted))" : "Expired"
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
