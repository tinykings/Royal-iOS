import Foundation

// Choices made in Settings, stored with @AppStorage under these keys.
enum Preference {
    static let redditLayout = "redditLayout"
    static let youtubeLayout = "youtubeLayout"
    static let redditOpen = "redditOpen"
    static let hnOpen = "hnOpen"
    static let youtubePlayback = "youtubePlayback"
    static let listWhilePlaying = "listWhilePlaying"
}

// How Reddit and YouTube posts are shown.
enum FeedLayout: String, CaseIterable, Identifiable {
    case list, cards

    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Cards" }
}

// What tapping a Reddit or Hacker News post opens; the other is in its long-press menu.
enum OpenTarget: String, CaseIterable, Identifiable {
    case link, comments

    var id: String { rawValue }
    var title: String { self == .link ? "Link" : "Comments" }
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
