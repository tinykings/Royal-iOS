import SwiftUI

// Settings' opt-in toggle for syncing saved posts and seen posts with the desktop extension.
struct DesktopSyncSection: View {
    @EnvironmentObject private var store: FeedStore
    @ObservedObject var sync: SavedSync

    // Routine progress isn't shown; only something the user may need to act on.
    private var problem: String? {
        let routine = ["Synced.", "Syncing…", "Sync is off.", "Turning on sync…"]
        if sync.status.isEmpty || routine.contains(where: { sync.status.hasPrefix($0) }) { return nil }
        return sync.status
    }

    var body: some View {
        if SavedSync.containerIdentifier != nil {
            Section {
                Toggle("Sync with Desktop", isOn: Binding(
                    get: { sync.isOn || sync.pendingEnable },
                    set: { on in
                        if on { Task { await store.enableSavedSync() } } else { sync.disable() }
                    }))
                    .disabled(sync.busy && !sync.isOn && !sync.pendingEnable)
                if sync.pendingEnable && !sync.isOn {
                    Text("Waiting for iCloud. Sync turns on by itself once it's ready.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Desktop")
            } footer: {
                Text("Shares your saved posts, and which posts the All feed has already shown, with the Royal desktop browser extension through your private iCloud database. Posts seen on one device aren't new on the other at its next refresh. Use the same Apple Account on each device, and turn this on on each iPhone and iPad. Turning it on keeps the posts saved here.")
            }
        }
    }
}
