import CloudKit
import SwiftUI

// An isolated compatibility probe. It never reads or changes the user's feeds,
// existing iCloud key-value saves, or seen state.
struct CloudKitProbeView: View {
    @State private var message = "Hello from Royal iOS"
    @State private var status = "Read the private probe before writing."
    @State private var record: CKRecord?
    @State private var account: CKRecord.ID?
    @State private var hasRead = false
    @State private var busy = false
    @State private var accountGeneration = 0
    @State private var retryAfter: Date?

    private static let recordID = CKRecord.ID(recordName: "royal-sync-probe-v1")
    private var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RoyalCloudKitProbeContainer") as? String,
              value.hasPrefix("iCloud."), !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        List {
            Section {
                Text("Test a private message with the desktop extension. Timeline, seen-state, and saved-item sync are not connected yet.")
            }
            if let identifier = containerIdentifier {
                Section("CloudKit") {
                    LabeledContent("Container", value: identifier)
                    LabeledContent("Environment", value: environment)
                    Text("Use the same Apple Account and CloudKit environment on desktop.")
                    Button("Read Private Probe") { Task { await read(identifier) } }
                        .disabled(busy || isThrottled)
                }
                Section("Shared message") {
                    Text(record?["message"] as? String ?? "No probe loaded")
                        .textSelection(.enabled)
                    if let date = record?["writtenAt"] as? String {
                        Text(date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("New message", text: $message)
                    Button("Write Private Probe") { Task { await write(identifier) } }
                        .disabled(busy || isThrottled || !hasRead || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 500)
                } footer: {
                    Text("Read before writing. If another client changes the probe, read again to use its newer revision.")
                }
            } else {
                Section("Setup required") {
                    Text("CloudKit is not configured for this build. See desktop/README.md in the repository for setup.")
                }
            }
            Section { Text(status).textSelection(.enabled) }
        }
        .navigationTitle("iCloud Sync Experiment")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            accountGeneration += 1
            record = nil
            account = nil
            hasRead = false
            status = "Apple Account changed. Read the probe again."
        }
    }

    private var isThrottled: Bool {
        guard let retryAfter else { return false }
        return retryAfter > Date()
    }

    /// Checks the device's iCloud account locally before any authenticated call,
    /// so a signed-out or restricted account never reaches accountsd's rate limit.
    private func requireAvailableAccount(_ container: CKContainer) async throws -> String? {
        switch try await container.accountStatus() {
        case .available: return nil
        case .noAccount: return "No Apple Account is signed in to iCloud on this device. Sign in from Settings, then read again."
        case .restricted: return "iCloud is restricted on this device (Screen Time or device management)."
        case .temporarilyUnavailable: return "iCloud needs attention. Open Settings › Apple Account and confirm your sign-in, then read again."
        case .couldNotDetermine: return "iCloud account status could not be determined. Try again shortly."
        @unknown default: return "iCloud account is unavailable."
        }
    }

    /// Turns throttling and account errors into guidance, and blocks retries until
    /// CloudKit's suggested delay passes so repeated taps don't extend the throttle.
    private func describe(_ error: Error, action: String) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        let ckError = error as? CKError
        let throttled = ckError?.code == .requestRateLimited || ckError?.code == .zoneBusy
            || ckError?.code == .serviceUnavailable || text.localizedCaseInsensitiveContains("throttl")
        if throttled {
            let seconds = ckError?.retryAfterSeconds ?? 60
            retryAfter = Date().addingTimeInterval(seconds)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if let retryAfter, retryAfter <= Date() { self.retryAfter = nil }
            }
            return "iCloud is rate-limiting sign-in requests from this device (\(text)). Wait about \(Int(seconds.rounded(.up))) seconds before trying again. If it keeps happening, open Settings › Apple Account to confirm your sign-in."
        }
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
        let combined = text + " " + underlying
        let passwordPrompt = combined.localizedCaseInsensitiveContains("password")
            || combined.localizedCaseInsensitiveContains("rejected a prompt")
        if ckError?.code == .accountTemporarilyUnavailable || passwordPrompt {
            return "iOS needs your Apple Account password to confirm iCloud, and the prompt was dismissed or didn't finish. Open Settings › Apple Account, enter your password when asked, then read again."
        }
        if ckError?.code == .notAuthenticated {
            return "iCloud is not signed in or needs you to sign in again. Open Settings › Apple Account, then read again."
        }
        return "CloudKit \(action) failed: \(text)"
    }

    private var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "RoyalCloudKitProbeEnvironment") as? String ?? "Unknown"
    }

    @MainActor
    private func read(_ identifier: String) async {
        let generation = accountGeneration
        busy = true
        hasRead = false
        record = nil
        account = nil
        defer { busy = false }
        do {
            let container = CKContainer(identifier: identifier)
            if let problem = try await requireAvailableAccount(container) {
                guard generation == accountGeneration else { return }
                status = problem
                return
            }
            let currentAccount = try await container.userRecordID()
            let fetched: CKRecord?
            do {
                fetched = try await container.privateCloudDatabase.record(for: Self.recordID)
            } catch let error as CKError where error.code == .unknownItem {
                // A missing probe is allowed; other errors must not permit a write.
                fetched = nil
            }
            guard generation == accountGeneration else { return }
            record = fetched
            account = currentAccount
            hasRead = true
            status = record == nil ? "No probe yet. Write a message to create one." : "Private probe read."
        } catch {
            guard generation == accountGeneration else { return }
            status = describe(error, action: "read")
        }
    }

    @MainActor
    private func write(_ identifier: String) async {
        guard hasRead, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.count <= 500 else { return }
        busy = true
        let generation = accountGeneration
        defer { busy = false }
        do {
            let container = CKContainer(identifier: identifier)
            guard try await container.userRecordID() == account else {
                hasRead = false
                record = nil
                status = "Apple Account changed. Read the probe again."
                return
            }
            guard generation == accountGeneration else { return }
            let updated = (record?.copy() as? CKRecord) ?? CKRecord(recordType: "RoyalSyncProbe", recordID: Self.recordID)
            updated["message"] = message.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
            updated["writtenAt"] = ISO8601DateFormatter().string(from: Date()) as NSString
            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [updated], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
            )
            guard generation == accountGeneration else { return }
            guard let saved = result.saveResults[Self.recordID] else {
                hasRead = false
                status = "CloudKit returned no result. Read the probe again."
                return
            }
            record = try saved.get()
            status = "Private probe written. Read it on desktop to verify sync."
        } catch {
            guard generation == accountGeneration else { return }
            hasRead = false
            // Fetch before retrying; never force-overwrite a conflicting revision.
            status = describe(error, action: "write") + " Read the probe again."
        }
    }
}
