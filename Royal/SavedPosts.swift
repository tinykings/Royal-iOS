import Foundation

// A post the user saved, kept with its full details so it stays listed even after
// it drops out of every feed.
struct SavedPost: Codable {
    let post: FeedPost
    let savedAt: Date
}

// This device's own saved posts, used while CloudKit sync (SavedSync) isn't active
// yet: before the first iCloud sign-in, or with no Apple Account signed in. When sync
// turns on for an account, they're imported into its synced library. Kept in
// UserDefaults on this device only.
//
// Royal used to sync this list through iCloud key-value storage. That copy is read
// once, so saves that only reached this device that way aren't lost, and never
// written again.
enum SavedPostsStorage {
    private static let key = "savedPosts"
    private static let modifiedKey = "savedPostsModified"
    // Data that couldn't be read, kept so a later version can recover it.
    private static let unreadableKey = "savedPostsUnreadable"
    private static let keyValueImportedKey = "savedPostsKeyValueImported"

    static func load() -> [SavedPost] {
        importKeyValueStoreOnce()
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return decode(data)
    }

    // Takes the key-value copy when it's newer than this device's, as the old
    // newest-wins rule did; a copy with no time recorded wins a tie.
    private static func importKeyValueStoreOnce() {
        let local = UserDefaults.standard
        guard !local.bool(forKey: keyValueImportedKey) else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        let cloudModified = cloud.object(forKey: modifiedKey) as? Double ?? 0
        let localModified = local.object(forKey: modifiedKey) as? Double ?? 0
        if let data = cloud.data(forKey: key), local.data(forKey: key) == nil || cloudModified >= localModified {
            local.set(data, forKey: key)
            local.set(cloudModified, forKey: modifiedKey)
        }
        local.set(true, forKey: keyValueImportedKey)
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
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: modifiedKey)
    }
}
