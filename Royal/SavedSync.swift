import CloudKit
import Foundation

// Syncs saved posts and seen posts between devices and with the desktop extension
// through the RoyalSync zone of the private CloudKit database (docs/sync-schema.md).
// Always on: it turns itself on for the Apple Account signed in to iCloud, and once
// it has, the synced library is what the Saved tab shows. Until then (no account, or
// iCloud not ready) FeedStore keeps saves in SavedPostsStorage, which is imported when
// sync turns on. Seen (RoyalSeen) is merged into the All feed's seen ids, so a post
// shown on another device isn't new here at the next refresh. The All snapshot record
// is left alone.
//
// Like the desktop it syncs when the app opens or returns to the foreground, about
// 1.5 s after each change, and before an All refresh. There's no background timer.
@MainActor
final class SavedSync: ObservableObject {
    struct Settings: Codable, Equatable {
        let container: String
        let environment: String
        // The Apple Account's userRecordName.
        let account: String
    }

    @Published private(set) var settings: Settings?
    @Published private(set) var library = SavedSyncLibrary()
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    // Sync hasn't turned on for an Apple Account yet: none is signed in, or iCloud
    // wasn't ready (throttled, offline, or the sign-in needed confirming). Royal keeps trying.
    @Published private(set) var pendingEnable = true

    // Called whenever the saved list, the seen ids, or whether sync is active may have changed.
    var onChange: (() -> Void)?
    // This device's All feed seen ids and sources, offered when sync turns on.
    var localSeen: (() -> (ids: [String], sources: [String]))?

    private static let settingsKey = "savedSyncSettings"
    // Written by builds where sync was opt-in.
    private static let legacyPendingEnableKey = "savedSyncPendingEnable"
    private static let zoneID = CKRecordZone.ID(zoneName: "RoyalSync", ownerName: CKCurrentUserDefaultName)
    private var verifiedAccount = false
    private var again = false
    private var scheduled: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?
    // No request before this time: iCloud asked Royal to wait, or a retry is backing off.
    // Opening the app or saving a post meanwhile waits too, so it can't extend a throttle.
    private var notBefore: Date?
    private var failures = 0

    static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RoyalCloudKitContainer") as? String,
              value.hasPrefix("iCloud.") else { return nil }
        return value
    }

    static var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "RoyalCloudKitEnvironment") as? String ?? "Unknown"
    }

    var isOn: Bool { settings != nil }

    // Whether the Saved tab shows the synced library.
    var isActive: Bool { configurationMatches }

    private var configurationMatches: Bool {
        guard let settings else { return false }
        return settings.container == Self.containerIdentifier && settings.environment == Self.environment
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = stored
            if configurationMatches {
                library = Self.loadLibrary(stored) ?? SavedSyncLibrary()
                pendingEnable = false
            } else {
                // A build for another container or environment (Debug vs. TestFlight):
                // turn on afresh for this one. The other's library file stays.
                settings = nil
                UserDefaults.standard.removeObject(forKey: Self.settingsKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyPendingEnableKey)
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A new situation: try again at once.
                self.verifiedAccount = false
                self.notBefore = nil
                self.failures = 0
                self.scheduleSync(after: 0)
            }
        }
    }

    // MARK: Turning sync on and off

    // Turns sync on for the signed-in Apple Account, importing this device's own saves
    // (SavedPostsStorage) and seen ids. Earlier synced data for the same account on this
    // device is picked up again. If iCloud isn't ready, it's tried again later.
    private func attemptEnable() async {
        guard pendingEnable, !isOn, let identifier = Self.containerIdentifier, !busy else { return }
        busy = true
        status = "Turning on sync…"
        do {
            let container = CKContainer(identifier: identifier)
            try await Self.checkAccount(container)
            let account = try await container.userRecordID().recordName
            let new = Settings(container: identifier, environment: Self.environment, account: account)
            library = Self.loadLibrary(new) ?? SavedSyncLibrary()
            library.importLocal(SavedPostsStorage.load())
            if let local = localSeen?() { library.noteSeen(ids: local.ids, sources: local.sources) }
            settings = new
            verifiedAccount = true
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
            pendingEnable = false
            persist()
            // They're this account's now, kept with its pending intentions; what stays
            // here is only what's saved while no account is syncing.
            SavedPostsStorage.save([])
        } catch {
            busy = false
            handle(error, enabling: true)
            return
        }
        busy = false
        await sync()
    }

    // Another Apple Account signed in to iCloud: hide this one's library, keeping its
    // file and pending intentions for when it signs in again, and turn on for the new one.
    private func switchAccount() {
        settings = nil
        verifiedAccount = false
        UserDefaults.standard.removeObject(forKey: Self.settingsKey)
        library = SavedSyncLibrary()
        pendingEnable = true
        onChange?()
    }

    // MARK: Local changes

    func setSaved(_ post: FeedPost, _ isSaved: Bool) {
        guard isActive else { return }
        library.setSaved(post, isSaved)
        persist()
        scheduleSync()
    }

    // Saves made on this device before sync turned on.
    func importLocal(_ saved: [SavedPost]) {
        guard isActive, library.importLocal(saved) else { return }
        persist()
        scheduleSync()
    }

    // What this device's All feed has shown; merged and sent.
    func noteSeen(ids: [String], sources: [String]) {
        guard isActive, library.noteSeen(ids: ids, sources: sources) else { return }
        persist()
        scheduleSync()
    }

    // Waits, up to `timeout`, for a sync in progress to finish; returns at once if none is.
    // An All refresh waits so posts another device has shown don't count as new.
    func waitUntilIdle(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while busy && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // Also finishes turning sync on when that's still pending.
    func scheduleSync(after seconds: Double = 1.5) {
        guard configurationMatches || (pendingEnable && !isOn) else { return }
        let wait = max(seconds, notBefore?.timeIntervalSinceNow ?? 0)
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            // Run apart from this task, so a later schedule can't cancel a sync midway.
            Task { await self?.run() }
        }
    }

    private func run() async {
        if pendingEnable && !isOn { await attemptEnable() } else { await sync() }
    }

    // MARK: Syncing

    func sync() async {
        guard configurationMatches else { return }
        if busy {
            again = true
            return
        }
        busy = true
        repeat {
            again = false
            do {
                status = "Syncing…"
                status = try await runSync()
                failures = 0
                notBefore = nil
            } catch {
                handle(error, enabling: false)
            }
        } while again && configurationMatches && notBefore == nil
        busy = false
        // The Apple Account changed during the sync.
        if pendingEnable && !isOn { await attemptEnable() }
    }

    private struct Paused: Error {
        let message: String
        var retry: Retry = .later
    }

    // Pulls zone changes, then pushes pending intentions with conditional writes,
    // pulling again after conflicts. Mirrors desktop/sync-runner.mjs.
    private func runSync() async throws -> String {
        guard let settings else { throw Paused(message: "Sync is off.") }
        let container = CKContainer(identifier: settings.container)
        try await Self.checkAccount(container)
        // userRecordID asks Apple's account service, which throttles repeated requests,
        // so it's checked once per launch and after the account changes.
        if !verifiedAccount {
            let current = try await container.userRecordID().recordName
            if current != settings.account {
                switchAccount()
                return "Switching to the Apple Account signed in to iCloud…"
            }
            verifiedAccount = true
        }
        let database = container.privateCloudDatabase
        if !library.zoneReady { try await ensureZone(database) }

        var pulled = 0, pushed = 0, failed = 0
        for _ in 0..<4 {
            pulled += try await pull(database)
            let pending = library.pending.map { PushItem.saved(postID: $0.postID, rev: $0.rev) }
                + (library.seenDirty.map { [PushItem.seen(rev: $0)] } ?? [])
            if pending.isEmpty { break }
            var retry = false
            for start in stride(from: 0, to: pending.count, by: 100) {
                let batch = Array(pending[start..<min(start + 100, pending.count)])
                let records = batch.compactMap { record(for: $0) }
                let result = try await database.modifyRecords(
                    saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                for item in batch {
                    let id = CKRecord.ID(recordName: item.recordName, zoneID: Self.zoneID)
                    switch result.saveResults[id] ?? .failure(CKError(.internalError)) {
                    case .success(let saved):
                        switch item {
                        case .saved(let postID, let rev):
                            library.pushSucceeded(postID: postID, rev: rev, systemFields: Self.archive(saved))
                        case .seen(let rev):
                            library.seenPushSucceeded(rev: rev, systemFields: Self.archive(saved))
                        }
                        pushed += 1
                    case .failure(let error as CKError) where error.code == .serverRecordChanged:
                        // Seen needs nothing more: the newer revision is merged below and sent again.
                        if case .saved(let postID, _) = item { library.pushConflicted(postID: postID) }
                        if let server = error.serverRecord { apply(server) }
                        retry = true
                    case .failure(let error as CKError) where Self.isZoneMissing(error):
                        library.zoneLost()
                        retry = true
                    default:
                        failed += 1
                    }
                }
                persist()
            }
            if !retry { break }
            if !library.zoneReady { try await ensureZone(database) }
        }
        library.lastSync = Date()
        persist()
        var summary = "Synced. Received \(pulled), sent \(pushed)."
        if failed > 0 { summary += " \(failed) couldn't be sent and will be tried again." }
        if library.pendingCount > 0 { summary += " \(library.pendingCount) pending." }
        return summary
    }

    private enum PushItem {
        case saved(postID: String, rev: Int)
        case seen(rev: Int)

        var recordName: String {
            switch self {
            case .saved(let postID, _): SavedSyncCodec.recordName(postID)
            case .seen: SeenSyncCodec.recordName
            }
        }
    }

    // Every page of changes since the stored token.
    private func pull(_ database: CKDatabase) async throws -> Int {
        var pulled = 0
        for _ in 0..<50 {
            let token = library.changeToken.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
                for result in changes.modificationResultsByID.values {
                    guard case .success(let modification) = result else { continue }
                    apply(modification.record)
                    pulled += 1
                }
                for deletion in changes.deletions {
                    if deletion.recordID.zoneID == Self.zoneID && deletion.recordID.recordName == SeenSyncCodec.recordName {
                        library.applyRemoteSeenDeletion()
                        continue
                    }
                    guard deletion.recordID.zoneID == Self.zoneID,
                          let postID = SavedSyncCodec.postID(fromRecordName: deletion.recordID.recordName) else { continue }
                    library.applyRemoteDeletion(postID: postID)
                }
                library.changeToken = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
                persist()
                if !changes.moreComing { break }
            } catch let error as CKError where Self.isZoneMissing(error) {
                // Deleted, for example from iCloud settings. Start over, keeping pending
                // intentions; every record is created anew.
                library.zoneLost()
                try await ensureZone(database)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                library.changeToken = nil
            }
        }
        return pulled
    }

    private func apply(_ record: CKRecord) {
        if record.recordType == SeenSyncCodec.recordType, record.recordID.zoneID == Self.zoneID,
           record.recordID.recordName == SeenSyncCodec.recordName {
            let seen = SeenSyncCodec.decode(
                ids: record["ids"] as? String, sources: record["sources"] as? String,
                schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue)
            library.applyRemoteSeen(ids: seen?.ids, sources: seen?.sources, systemFields: Self.archive(record))
            return
        }
        guard record.recordType == SavedSyncCodec.recordType, record.recordID.zoneID == Self.zoneID,
              let postID = SavedSyncCodec.postID(fromRecordName: record.recordID.recordName) else { return }
        let save = SavedSyncCodec.decode(
            recordName: record.recordID.recordName, postID: record["postID"] as? String,
            post: record["post"] as? String, savedAt: record["savedAt"] as? String,
            isSaved: (record["isSaved"] as? NSNumber)?.intValue,
            schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue)
        library.applyRemote(postID: postID, save: save, systemFields: Self.archive(record))
    }

    // The record to write: the last known revision when there is one, so the write is
    // conditional on it; otherwise a new record, which fails if another client created it.
    private func record(for item: PushItem) -> CKRecord? {
        switch item {
        case .saved(let postID, _): return record(for: postID)
        case .seen:
            let id = CKRecord.ID(recordName: SeenSyncCodec.recordName, zoneID: Self.zoneID)
            let record = library.seenSystemFields.flatMap(Self.unarchiveRecord)
                ?? CKRecord(recordType: SeenSyncCodec.recordType, recordID: id)
            record["ids"] = SeenSyncCodec.encode(library.seen) as NSString
            record["sources"] = SeenSyncCodec.encode(library.seenSources) as NSString
            record["schemaVersion"] = NSNumber(value: Int64(SavedSyncCodec.schemaVersion))
            return record
        }
    }

    private func record(for postID: String) -> CKRecord? {
        guard let entry = library.entries[postID] else { return nil }
        let id = CKRecord.ID(recordName: SavedSyncCodec.recordName(postID), zoneID: Self.zoneID)
        let record = library.systemFields[postID].flatMap(Self.unarchiveRecord)
            ?? CKRecord(recordType: SavedSyncCodec.recordType, recordID: id)
        record["postID"] = postID as NSString
        record["post"] = SavedSyncCodec.encodePost(entry.post) as NSString
        record["savedAt"] = entry.savedAt as NSString
        record["isSaved"] = NSNumber(value: Int64(entry.isSaved ? 1 : 0))
        record["schemaVersion"] = NSNumber(value: Int64(SavedSyncCodec.schemaVersion))
        return record
    }

    private func ensureZone(_ database: CKDatabase) async throws {
        let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        if case .failure(let error)? = result.saveResults[Self.zoneID] { throw error }
        library.zoneReady = true
        persist()
    }

    // MARK: Storage

    private func persist() {
        if let settings, let data = try? JSONEncoder().encode(library) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.libraryURL(settings), options: .atomic)
        }
        onChange?()
    }

    // One library per container, environment, and Apple Account, so another account's
    // data and pending intentions are kept apart.
    private static func libraryURL(_ settings: Settings) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let name = [settings.container, settings.environment, settings.account]
            .map { String($0.unicodeScalars.filter(allowed.contains)) }
            .joined(separator: "-")
        return URL.applicationSupportDirectory.appending(path: "saved-sync-\(name).json")
    }

    private static func loadLibrary(_ settings: Settings) -> SavedSyncLibrary? {
        guard let data = try? Data(contentsOf: libraryURL(settings)) else { return nil }
        return try? JSONDecoder().decode(SavedSyncLibrary.self, from: data)
    }

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func unarchiveRecord(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Errors

    private static func isZoneMissing(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    // When to try again after a failure.
    private enum Retry {
        // On a timer: after iCloud's suggested wait, or backing off when it gave none.
        case timer(Double?)
        // When the app returns to the foreground or the Apple Account changes, since it
        // needs the person (a password prompt, a sign-in).
        case later
        case never
    }

    // Checked on the device, before any request that has to authenticate.
    private static func checkAccount(_ container: CKContainer) async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw Paused(message: "No Apple Account is signed in to iCloud on this device.")
        case .restricted:
            throw Paused(message: "iCloud is restricted on this device.")
        case .temporarilyUnavailable:
            throw Paused(message: "iCloud needs attention. Open Settings › Apple Account and confirm your sign-in.")
        case .couldNotDetermine:
            throw Paused(message: "iCloud account status could not be determined.", retry: .timer(nil))
        @unknown default:
            throw Paused(message: "iCloud is unavailable.")
        }
    }

    private func handle(_ error: Error, enabling: Bool) {
        let (message, retry) = Self.classify(error)
        switch retry {
        case .timer(let suggested):
            let backoff = min(30 * pow(2, Double(min(failures, 5))), 600)
            let delay = max(suggested ?? backoff, 5)
            failures += 1
            notBefore = Date().addingTimeInterval(delay)
            status = message + " Royal will try again in about \(Self.duration(delay))."
            scheduleSync(after: 0)
        case .later:
            status = message + " Royal will try again when you return to the app."
        case .never:
            status = enabling ? "Couldn't turn on sync. " + message : message
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded(.up))) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }

    private static func classify(_ error: Error) -> (String, Retry) {
        if let paused = error as? Paused { return (paused.message, paused.retry) }
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
        let text = nsError.localizedDescription
        let combined = text + " " + underlying
        let ckError = error as? CKError
        switch ckError?.code {
        case .networkUnavailable?, .networkFailure?:
            return ("Offline. Changes are kept.", .timer(nil))
        case .requestRateLimited?, .serviceUnavailable?, .zoneBusy?:
            return ("iCloud asked Royal to wait. Changes are kept.", .timer(ckError?.retryAfterSeconds))
        case .notAuthenticated?, .accountTemporarilyUnavailable?:
            return ("iCloud needs your Apple Account password confirmed. Open Settings › Apple Account if it asks.", .later)
        case .unknownItem?, .invalidArguments?, .serverRejectedRequest?:
            return ("CloudKit rejected the request (\(text)). The RoyalSavedPost or RoyalSeen record type may not be deployed to \(environment) yet; see desktop/README.md.", .never)
        default:
            break
        }
        // Apple's account service reports these without a CloudKit error code.
        if combined.localizedCaseInsensitiveContains("throttl") {
            return ("iCloud is rate-limiting sign-in requests from this device.", .timer(60))
        }
        if combined.localizedCaseInsensitiveContains("password") || combined.localizedCaseInsensitiveContains("rejected a prompt") {
            return ("iCloud needs your Apple Account password confirmed, and the prompt was dismissed.", .later)
        }
        if ckError != nil { return ("Sync failed: \(text)", .timer(nil)) }
        return ("Sync failed: \(text)", .never)
    }
}
