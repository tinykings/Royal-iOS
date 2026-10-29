import SwiftUI

// Choices made in Settings, stored with @AppStorage under these keys.
enum Preference {
    static let redditLayout = "redditLayout"
    static let youtubeLayout = "youtubeLayout"
    static let redditOpen = "redditOpen"
    static let hnOpen = "hnOpen"
    static let youtubePlayback = "youtubePlayback"
    static let listWhilePlaying = "listWhilePlaying"
    static let feedTextSize = "feedTextSize"
    // Whether the All feed's first-open login card has been finished.
    static let setupComplete = "setupComplete"
}

// Text size for feed posts, a step on the Settings slider. Applied as a Dynamic
// Type size so titles, details and icons all scale together.
enum FeedTextSize: Int, CaseIterable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge

    static let standard = FeedTextSize.large

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall: .xSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .xLarge
        case .xxLarge: .xxLarge
        case .xxxLarge: .xxxLarge
        }
    }

    var title: String {
        switch self {
        case .xSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Default"
        case .xLarge: "Large"
        case .xxLarge: "Extra Large"
        case .xxxLarge: "Huge"
        }
    }
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
