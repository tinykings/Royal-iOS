import XCTest
@testable import Royal

// The sync rules in docs/sync-schema.md, on the plain values SavedSync pushes and pulls.
final class SavedSyncLibraryTests: XCTestCase {
    private func post(_ id: String, source: FeedSource = .reddit, url: String? = nil,
                      videoId: String? = nil, watchLater: Bool? = nil) -> FeedPost {
        FeedPost(source: source, id: id, title: "Title \(id)", url: url ?? "https://example.com/\(id)",
                 commentsUrl: "https://example.com/\(id)#c", label: "r/test", score: nil, comments: nil,
                 created: nil, image: nil, imageAspect: nil, videoId: videoId, published: nil,
                 publishedAt: nil, nsfw: nil, watchLater: watchLater)
    }

    func testSavingAndUnsavingLeavesATombstoneWithThePost() {
        var library = SavedSyncLibrary()
        library.setSaved(post("a"), true, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(library.savedPosts.map(\.post.id), ["a"])
        XCTAssertEqual(library.pending.map(\.postID), ["a"])
        library.setSaved(post("a"), false, now: Date(timeIntervalSince1970: 2000))
        XCTAssertTrue(library.savedPosts.isEmpty)
        XCTAssertEqual(library.entries["a"]?.isSaved, false)
        XCTAssertEqual(library.entries["a"]?.post.title, "Title a")
        XCTAssertEqual(library.entries["a"]?.savedAt, "1970-01-01T00:33:20.000Z")
    }

    func testSavedPostsAreNewestFirst() {
        var library = SavedSyncLibrary()
        library.setSaved(post("old"), true, now: Date(timeIntervalSince1970: 1000))
        library.setSaved(post("new"), true, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(library.savedPosts.map(\.post.id), ["new", "old"])
    }

    func testAPendingSaveIsWrittenAgainOverANewerRemoteRevision() {
        var library = SavedSyncLibrary()
        library.setSaved(post("a"), true)
        let remote = SyncedSave(post: post("a"), savedAt: "2030-01-01T00:00:00.000Z", isSaved: false)
        library.applyRemote(postID: "a", save: remote, systemFields: Data([1]))
        XCTAssertEqual(library.entries["a"]?.isSaved, true)
        XCTAssertNotNil(library.dirty["a"])
        XCTAssertEqual(library.systemFields["a"], Data([1]), "the remote revision is kept so the write can succeed")
        library.pushConflicted(postID: "a")
        XCTAssertNotNil(library.dirty["a"], "a save isn't dropped by a conflict")
    }

    func testAnImportYieldsToAnyRemoteRecord() {
        var library = SavedSyncLibrary()
        XCTAssertTrue(library.importLocal([SavedPost(post: post("b"), savedAt: Date())]))
        let tombstone = SyncedSave(post: post("b"), savedAt: "2030-01-01T00:00:00.000Z", isSaved: false)
        library.applyRemote(postID: "b", save: tombstone, systemFields: nil)
        XCTAssertEqual(library.entries["b"]?.isSaved, false)
        XCTAssertNil(library.dirty["b"])
        XCTAssertFalse(library.importLocal([SavedPost(post: post("b"), savedAt: Date())]),
                       "a post the library knows isn't imported again")

        var conflicted = SavedSyncLibrary()
        conflicted.importLocal([SavedPost(post: post("c"), savedAt: Date())])
        conflicted.pushConflicted(postID: "c")
        XCTAssertNil(conflicted.dirty["c"])
    }

    func testAPushOnlyClearsTheRevisionItSent() {
        var library = SavedSyncLibrary()
        library.setSaved(post("a"), true)
        let sent = library.pending[0].rev
        library.setSaved(post("a"), false)
        library.pushSucceeded(postID: "a", rev: sent, systemFields: nil)
        XCTAssertNotNil(library.dirty["a"], "changed again while the push was in flight")
        library.pushSucceeded(postID: "a", rev: library.pending[0].rev, systemFields: nil)
        XCTAssertNil(library.dirty["a"])
    }

    func testARemoteDeletionDropsOnlyCleanCopies() {
        var library = SavedSyncLibrary()
        library.applyRemote(postID: "clean", save: SyncedSave(post: post("clean"), savedAt: "2026-11-10T00:00:00.000Z", isSaved: true),
                            systemFields: Data([1]))
        library.setSaved(post("pending"), true)
        library.applyRemoteDeletion(postID: "clean")
        library.applyRemoteDeletion(postID: "pending")
        XCTAssertNil(library.entries["clean"])
        XCTAssertNil(library.systemFields["clean"])
        XCTAssertNotNil(library.entries["pending"])
    }

    func testAWatchLaterVideoKeepsItsMarkThroughAnUnsaveUntilCleared() {
        var library = SavedSyncLibrary()
        let video = post("yt_abcdefghijk", source: .youtube, videoId: "abcdefghijk", watchLater: true)
        library.setSaved(video, true)
        library.setSaved(post("yt_abcdefghijk", source: .youtube, videoId: "abcdefghijk"), false)
        XCTAssertEqual(library.watchLaterRemovals, ["abcdefghijk"])
        library.clearWatchLater(postID: "yt_abcdefghijk")
        XCTAssertEqual(library.watchLaterRemovals, [])
        XCTAssertNotNil(library.dirty["yt_abcdefghijk"], "the cleared mark is sent")
    }

    func testZoneLossKeepsIntentionsAndResendsSeen() {
        var library = SavedSyncLibrary()
        library.setSaved(post("a"), true)
        library.noteSeen(ids: ["x"], sources: ["reddit"])
        library.seenPushSucceeded(rev: library.seenDirty!, systemFields: Data([1]))
        library.zoneReady = true
        library.zoneLost()
        XCTAssertFalse(library.zoneReady)
        XCTAssertNil(library.seenSystemFields)
        XCTAssertNotNil(library.seenDirty)
        XCTAssertNotNil(library.dirty["a"])
    }

    // MARK: Seen

    func testSeenMergesByUnionAndSendsWhatTheRemoteLacks() {
        var library = SavedSyncLibrary()
        XCTAssertTrue(library.noteSeen(ids: ["a", "b"], sources: ["reddit"]))
        XCTAssertFalse(library.noteSeen(ids: ["a"], sources: ["reddit"]), "nothing new to send")
        library.seenPushSucceeded(rev: library.seenDirty!, systemFields: nil)
        XCTAssertNil(library.seenDirty)
        library.applyRemoteSeen(ids: ["c", "a"], sources: ["hn", "bogus"], systemFields: nil)
        XCTAssertEqual(library.seen, ["c", "a", "b"])
        XCTAssertEqual(library.seenSources, ["hn", "reddit"])
        XCTAssertNotNil(library.seenDirty, "b is only here, so it's sent")
    }

    func testSeenKeepsTheNewestIDsUnderTheLimit() {
        let remote = (0..<SeenSyncCodec.limit).map { "r\($0)" }
        let merged = SeenSyncCodec.merge(remote: remote, local: ["r5", "new"])
        XCTAssertEqual(merged.count, SeenSyncCodec.limit)
        XCTAssertEqual(merged.first, "r1")
        XCTAssertEqual(merged.last, "new")
    }

    // MARK: Records

    func testRecordsAreDecodedOnlyWhenRoyalUnderstandsThem() {
        let json = SavedSyncCodec.encodePost(post("a"))
        let savedAt = "2026-11-10T22:04:05.123Z"
        XCTAssertNotNil(SavedSyncCodec.decode(recordName: "saved.a", postID: "a", post: json, savedAt: savedAt,
                                              isSaved: 1, schemaVersion: 1))
        XCTAssertNil(SavedSyncCodec.decode(recordName: "saved.a", postID: "a", post: json, savedAt: savedAt,
                                           isSaved: 1, schemaVersion: 2), "a newer schema is left alone")
        XCTAssertNil(SavedSyncCodec.decode(recordName: "saved.b", postID: "a", post: json, savedAt: savedAt,
                                           isSaved: 1, schemaVersion: 1))
        XCTAssertNil(SavedSyncCodec.decode(recordName: "saved.a", postID: "a", post: json, savedAt: "yesterday",
                                           isSaved: 1, schemaVersion: 1))
        let script = SavedSyncCodec.encodePost(post("a", url: "javascript:alert(1)"))
        XCTAssertNil(SavedSyncCodec.decode(recordName: "saved.a", postID: "a", post: script, savedAt: savedAt,
                                           isSaved: 1, schemaVersion: 1))
    }

    func testAVideosChannelSurvivesSync() {
        var video = post("yt_abcdefghijk", source: .youtube, videoId: "abcdefghijk")
        video.channelId = "UC1234567890123456789012"
        XCTAssertEqual(SavedSyncCodec.sanitized(video)?.channelId, "UC1234567890123456789012")
    }

    func testOlderSavesWithADescriptionStillDecode() {
        // RSS saves once carried the item's description as `summary`; it's ignored now.
        let json = #"{"source":"hn","id":"hn_42","title":"Story","url":"https://example.com/s","commentsUrl":"https://news.ycombinator.com/item?id=42","label":"Hacker News","summary":"<p>Old</p>"}"#
        let save = SavedSyncCodec.decode(recordName: "saved.hn_42", postID: "hn_42", post: json,
                                         savedAt: "2026-11-10T22:04:05.123Z", isSaved: 1, schemaVersion: 1)
        XCTAssertEqual(save?.post.source, .rss)
        XCTAssertEqual(save?.post.title, "Story")
    }
}
