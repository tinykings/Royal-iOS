import SafariServices
import SwiftUI

struct FeedListView<Trailing: View>: View {
    @EnvironmentObject private var store: FeedStore
    @Environment(\.openURL) private var openURL
    @State private var browserURL: BrowserURL?
    @State private var scrolledAway = false
    @AppStorage(Preference.redditLayout) private var redditLayout = FeedLayout.list
    @AppStorage(Preference.youtubeLayout) private var youtubeLayout = FeedLayout.list
    @AppStorage(Preference.redditOpen) private var redditOpen = OpenTarget.link
    @AppStorage(Preference.hnOpen) private var hnOpen = OpenTarget.link
    @AppStorage(Preference.youtubePlayback) private var youtubePlayback = VideoPlayback.inApp
    @AppStorage(Preference.listWhilePlaying) private var listWhilePlaying = false
    let title: String
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
        // The header slides away while scrolling down, and stays hidden while the
        // docked video player is showing, to leave more room for the feed.
        let headerHidden = scrolledAway || store.playingVideo != nil
        NavigationStack {
            List {
                ForEach(savedOnly ? [] : keys, id: \.self) { key in
                    if let error = store.state(key).error {
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
                } else if posts.isEmpty && keys.contains(where: { store.state($0).loading }) {
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
            }
            .listStyle(.plain)
            // Posts sit on tiles over the grouped background.
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .hidesHeaderOnScroll($scrolledAway)
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
                SafariView(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }

    private func postRow(_ post: FeedPost, nearEnd: Bool) -> some View {
        let isSaved = store.isSaved(post)
        return PostRow(post: post, showsSource: showsSource, layout: layout(for: post), saved: isSaved)
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
            browserURL = BrowserURL(url: url)
        }
    }
}

extension FeedListView where Trailing == EmptyView {
    init(title: String, keys: [FeedKey], showsSource: Bool = false) {
        self.init(title: title, keys: keys, showsSource: showsSource, savedOnly: false) { EmptyView() }
    }
}

private struct ScrollPosition: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
    var insetTop: CGFloat
}

extension View {
    // Sets `hidden` while scrolling down and clears it when scrolling up or reaching
    // the top. Needs iOS 18 scroll geometry; earlier versions keep the header.
    @ViewBuilder
    func hidesHeaderOnScroll(_ hidden: Binding<Bool>) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: ScrollPosition.self) { geometry in
                ScrollPosition(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                               maxOffset: geometry.contentSize.height - geometry.containerSize.height
                                   + geometry.contentInsets.top + geometry.contentInsets.bottom,
                               insetTop: geometry.contentInsets.top)
            } action: { old, new in
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
            self
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
    var id: String { url.absoluteString }
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
            .fill(Color.accentColor.opacity(0.6))
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
    @AppStorage(Preference.feedTextSize) private var textSize = FeedTextSize.standard

    static let cornerRadius: CGFloat = 14
    private static let inset: CGFloat = 12
    // Taller images are letterboxed to this shape so one image can't fill the screen.
    private static let tallestImageAspect = 0.85

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
        .dynamicTypeSize(textSize.dynamicTypeSize)
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
            HStack(spacing: 4) {
                if showsSource {
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
        if let score = post.score { parts.append("\(score) pts") }
        if let comments = post.comments { parts.append("\(comments) comments") }
        if let created = post.created { parts.append(age(created)) }
        if let published = post.published, !published.isEmpty { parts.append(published) }
        return parts.joined(separator: " · ")
    }

    private func age(_ created: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - created)
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
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
