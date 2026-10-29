import Foundation

// A post the user saved, kept with its full details so it stays listed even after
// it drops out of every feed.
struct SavedPost: Codable {
    let post: FeedPost
    let savedAt: Date
}

// Saved posts live in iCloud key-value storage so they follow the user across
// devices, mirrored to UserDefaults so they persist when iCloud is unavailable.
// Key-value storage holds up to 1 MB, roughly a couple of thousand posts; past that
// the list is kept on this device only.
enum SavedPostsStorage {
    private static let key = "savedPosts"
    private static let modifiedKey = "savedPostsModified"
    // Data that couldn't be read, kept so a later version can recover it.
    private static let unreadableKey = "savedPostsUnreadable"
    private static let cloudLimit = 1_000_000 - 1_000

    static func load() -> [SavedPost] {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        let local = UserDefaults.standard
        // Each copy records when it was written; the newer wins. Copies from before that
        // was recorded have no time, so a timed copy beats them, and iCloud wins a tie.
        let cloudModified = cloud.object(forKey: modifiedKey) as? Double ?? 0
        let localModified = local.object(forKey: modifiedKey) as? Double ?? 0
        let newest = localModified > cloudModified
            ? local.data(forKey: key) ?? cloud.data(forKey: key)
            : cloud.data(forKey: key) ?? local.data(forKey: key)
        guard let data = newest else { return [] }
        return decode(data)
    }

    // Decodes each post on its own, so one that no longer fits FeedPost drops alone
    // rather than emptying the list. Anything dropped is backed up first, since the
    // next save writes the list without it.
    private static func decode(_ data: Data) -> [SavedPost] {
        let items = (try? JSONDecoder().decode([Lenient].self, from: data)) ?? []
        let saved = items.compactMap(\.value)
        if saved.count < items.count || (items.isEmpty && data.count > 2) {
            UserDefaults.standard.set(data, forKey: unreadableKey)
        }
        return saved
    }

    private struct Lenient: Decodable {
        let value: SavedPost?

        init(from decoder: Decoder) throws {
            value = try? SavedPost(from: decoder)
        }
    }

    static func save(_ saved: [SavedPost]) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let modified = Date().timeIntervalSince1970
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(modified, forKey: modifiedKey)
        // Too big for iCloud: leave its older copy, which this device's newer one outranks.
        guard data.count <= cloudLimit else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.set(data, forKey: key)
        cloud.set(modified, forKey: modifiedKey)
    }
}
