import Foundation

// A post the user saved, kept with its full details so it stays listed even after
// it drops out of every feed.
struct SavedPost: Codable {
    let post: FeedPost
    let savedAt: Date
}

// Saved posts live in iCloud key-value storage so they follow the user across
// devices, mirrored to UserDefaults so they persist when iCloud is unavailable.
// Key-value storage holds up to 1 MB, roughly a couple of thousand posts.
enum SavedPostsStorage {
    private static let key = "savedPosts"

    static func load() -> [SavedPost] {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        guard let data = cloud.data(forKey: key) ?? UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedPost].self, from: data) else { return [] }
        return saved
    }

    static func save(_ saved: [SavedPost]) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
    }
}
