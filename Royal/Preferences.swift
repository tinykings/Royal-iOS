import SwiftUI

// Choices made in Settings, stored with @AppStorage under these keys.
enum Preference {
    static let redditLayout = "redditLayout"
    static let youtubeLayout = "youtubeLayout"
    static let redditOpen = "redditOpen"
    static let rssOpen = "rssOpen"
    // The RSS feeds, as JSON; unset until the list is first changed.
    static let rssFeeds = "rssFeeds"
    static let youtubePlayback = "youtubePlayback"
    static let listWhilePlaying = "listWhilePlaying"
    static let feedTextSize = "feedTextSize"
    // The Reddit tab's last chosen sort.
    static let redditSort = "redditSort"
    // Whether Reddit feeds include NSFW posts; off unless turned on in Settings.
    static let redditNSFW = "redditNSFW"
    // Sources turned off in Settings, comma separated. Their tabs show a dot and
    // their posts leave the All feed.
    static let disabledSources = "disabledSources"
}

// Text size for feed posts, a step on the Settings slider. Default follows the
// system text size; the other steps go that many sizes smaller or larger, reaching
// into the accessibility sizes. Applied as a Dynamic Type size so titles, details
// and icons all scale together.
enum FeedTextSize: Int, CaseIterable {
    case smaller3, smaller2, smaller1, system, larger1, larger2, larger3

    static let standard = FeedTextSize.system

    // The size to show text at when the system is set to `base`.
    func dynamicTypeSize(from base: DynamicTypeSize) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        let index = sizes.firstIndex(of: base) ?? sizes.firstIndex(of: .large)!
        let shifted = min(max(index + rawValue - Self.system.rawValue, 0), sizes.count - 1)
        return sizes[shifted]
    }

    var title: String {
        switch self {
        case .smaller3: "Much Smaller"
        case .smaller2: "Smaller"
        case .smaller1: "Slightly Smaller"
        case .system: "Default"
        case .larger1: "Slightly Larger"
        case .larger2: "Larger"
        case .larger3: "Much Larger"
        }
    }
}

extension View {
    // Shows feed text at the Settings size, relative to the system text size.
    func feedTextSize(_ size: FeedTextSize) -> some View {
        modifier(FeedTextSizeModifier(size: size))
    }
}

private struct FeedTextSizeModifier: ViewModifier {
    let size: FeedTextSize
    @Environment(\.dynamicTypeSize) private var base

    func body(content: Content) -> some View {
        content.dynamicTypeSize(size.dynamicTypeSize(from: base))
    }
}

// How Reddit and YouTube posts are shown.
enum FeedLayout: String, CaseIterable, Identifiable {
    case list, cards

    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Cards" }
}

// What tapping a Reddit post opens; the other is in its long-press menu.
enum OpenTarget: String, CaseIterable, Identifiable {
    case link, comments

    var id: String { rawValue }
    var title: String { self == .link ? "Link" : "Comments" }
}

// What tapping an RSS post opens: the item's description from the feed, or its link.
// The other, and the item's comments when it links some, are in its swipe and
// long-press menus.
enum RSSOpenTarget: String, CaseIterable, Identifiable {
    case description, link

    var id: String { rawValue }
    var title: String { self == .description ? "Description" : "Link" }
}

// Where tapping a YouTube video plays it.
enum VideoPlayback: String, CaseIterable, Identifiable {
    case inApp, browser, youtubeApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inApp: "In-app player"
        case .browser: "Safari"
        case .youtubeApp: "YouTube app"
        }
    }

    var icon: String {
        switch self {
        case .inApp: "play.rectangle"
        case .browser: "safari"
        case .youtubeApp: "arrow.up.forward.app"
        }
    }
}
