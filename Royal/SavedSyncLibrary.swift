import Foundation

// The iOS side of the RoyalSync saved-post records (docs/sync-schema.md), matching
// desktop/sync.mjs and desktop/library.mjs. Plain values only; SavedSync does the
// CloudKit requests.
//
// Local intentions are dirty marks, stored with the library so they survive being
// offline and relaunches, and coalesce per post. Each mark records the library's
// `rev` when it was made; a push clears it only if nothing changed the post again
// while the push was in flight.
//
// - The last accepted intention wins: a pending save or unsave is written again over
//   a newer remote revision.
// - Unsaves are tombstones (isSaved 0), never deletions.
// - An import (posts saved here before sync was on) never overwrites a remote record
//   or tombstone.

struct SyncedSave: Codable {
    var post: FeedPost
    // ISO 8601 UTC with milliseconds: the last save or unsave.
    var savedAt: String
    var isSaved: Bool
}

struct SavedSyncLibrary: Codable {
    enum Mode: String, Codable { case set, `import` }
    struct Mark: Codable {
        var rev: Int
        var mode: Mode
    }

    // postID -> its latest state, tombstones included.
    var entries: [String: SyncedSave] = [:]
    var dirty: [String: Mark] = [:]
    var rev = 0
    // An archived CKServerChangeToken for the RoyalSync zone.
    var changeToken: Data?
    var zoneReady = false
    // postID -> the record's archived CloudKit system fields (its change tag).
    var systemFields: [String: Data] = [:]
    var lastSync: Date?

    var pendingCount: Int { dirty.count }

    // Newest first, tombstones left out.
    var savedPosts: [SavedPost] {
        entries.values.filter(\.isSaved)
            .sorted { $0.savedAt > $1.savedAt }
            .map { SavedPost(post: $0.post, savedAt: SavedSyncCodec.date($0.savedAt) ?? .distantPast) }
    }

    // The posts with pending intentions, for a push.
    var pending: [(postID: String, rev: Int)] {
        dirty.compactMap { id, mark in entries[id] == nil ? nil : (id, mark.rev) }
            .sorted { $0.postID < $1.postID }
    }

    mutating func setSaved(_ post: FeedPost, _ isSaved: Bool, now: Date = Date()) {
        guard let post = SavedSyncCodec.sanitized(post) else { return }
        let existing = entries[post.id]
        if existing?.isSaved == isSaved { return }
        rev += 1
        entries[post.id] = SyncedSave(post: isSaved ? post : existing?.post ?? post,
                                      savedAt: SavedSyncCodec.iso(now), isSaved: isSaved)
        dirty[post.id] = Mark(rev: rev, mode: .set)
    }

    // Offers saves made outside sync. Only posts the library has no record of at all
    // are added, and a remote copy found later wins. Returns whether anything was added.
    @discardableResult
    mutating func importLocal(_ saved: [SavedPost]) -> Bool {
        var added = false
        for item in saved {
            guard entries[item.post.id] == nil, let post = SavedSyncCodec.sanitized(item.post) else { continue }
            if !added { rev += 1 }
            added = true
            entries[post.id] = SyncedSave(post: post, savedAt: SavedSyncCodec.iso(item.savedAt), isSaved: true)
            dirty[post.id] = Mark(rev: rev, mode: .import)
        }
        return added
    }

    // A remote record. `save` is nil when it couldn't be read (or is a newer schema);
    // its revision is still kept so a pending write can succeed.
    mutating func applyRemote(postID: String, save: SyncedSave?, systemFields fields: Data?) {
        if let fields { systemFields[postID] = fields }
        guard let save else { return }
        let pending = dirty[postID]
        if pending?.mode == .import { dirty[postID] = nil }
        if pending == nil || pending?.mode == .import { entries[postID] = save }
    }

    // Royal never deletes records; another client did. Forget the revision, and drop a
    // copy with no pending intention.
    mutating func applyRemoteDeletion(postID: String) {
        systemFields[postID] = nil
        if dirty[postID] == nil { entries[postID] = nil }
    }

    mutating func pushSucceeded(postID: String, rev pushedRev: Int, systemFields fields: Data?) {
        if let fields { systemFields[postID] = fields }
        if dirty[postID]?.rev == pushedRev { dirty[postID] = nil }
    }

    // Another client wrote first. An import yields to it; a save or unsave is written
    // again over the newer revision.
    mutating func pushConflicted(postID: String) {
        if dirty[postID]?.mode == .import { dirty[postID] = nil }
    }

    // The zone was deleted: every record is created anew, keeping pending intentions.
    mutating func zoneLost() {
        zoneReady = false
        changeToken = nil
        systemFields = [:]
    }
}

enum SavedSyncCodec {
    static let recordType = "RoyalSavedPost"
    static let schemaVersion = 1
    private static let prefix = "saved."

    static func recordName(_ postID: String) -> String { prefix + postID }

    static func postID(fromRecordName name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    private static let isoOut: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    // `2026-11-10T22:04:05.123Z`, as the desktop writes it.
    static func iso(_ date: Date) -> String { isoOut.string(from: date) }

    static func date(_ string: String) -> Date? {
        guard string.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$"#,
                           options: .regularExpression) != nil else { return nil }
        return isoOut.date(from: string) ?? isoPlain.date(from: string)
    }

    private static func httpURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return value
    }

    // The post with links limited to http(s), like desktop normalizePost; nil for
    // anything that can't be shown.
    static func sanitized(_ post: FeedPost) -> FeedPost? {
        guard let url = httpURL(post.url),
              post.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { return nil }
        return FeedPost(source: post.source, id: post.id, title: post.title, url: url,
                        commentsUrl: httpURL(post.commentsUrl) ?? url, label: post.label,
                        score: post.score, comments: post.comments, created: post.created,
                        image: httpURL(post.image), imageAspect: post.imageAspect, videoId: post.videoId,
                        published: post.published, publishedAt: post.publishedAt, nsfw: post.nsfw)
    }

    static func encodePost(_ post: FeedPost) -> String {
        let data = (try? JSONEncoder().encode(post)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // A RoyalSavedPost record's fields; nil when it's not one Royal understands,
    // including a newer schemaVersion, which is left alone rather than misread.
    static func decode(recordName: String, postID: String?, post: String?, savedAt: String?,
                       isSaved: Int?, schemaVersion: Int?) -> SyncedSave? {
        guard let schemaVersion, schemaVersion <= Self.schemaVersion,
              let postID, recordName == Self.recordName(postID),
              let data = post?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FeedPost.self, from: data),
              let clean = sanitized(decoded), clean.id == postID,
              let savedAt, let date = date(savedAt) else { return nil }
        return SyncedSave(post: clean, savedAt: iso(date), isSaved: isSaved == 1)
    }
}
