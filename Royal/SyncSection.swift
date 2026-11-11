import SwiftUI

// Settings' iCloud sync status. Sync is always on; this shows whether it's working
// and anything the user may need to act on.
struct SyncSection: View {
    @ObservedObject var sync: SavedSync

    private var summary: String {
        if sync.isOn { return sync.busy ? "Syncing…" : "On" }
        return sync.busy ? "Turning on…" : "Waiting for iCloud"
    }

    // Routine progress isn't shown; only something the user may need to act on.
    private var problem: String? {
        let routine = ["Synced.", "Syncing…", "Turning on sync…", "Switching to the Apple Account"]
        if sync.status.isEmpty || routine.contains(where: { sync.status.hasPrefix($0) }) { return nil }
        return sync.status
    }

    var body: some View {
        if SavedSync.containerIdentifier != nil {
            Section {
                LabeledContent("iCloud Sync", value: summary)
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text(sync.isOn
                     ? "Saved posts, and which posts the All feed has already shown, sync through your private iCloud database with your other devices and the Royal desktop browser extension. Posts seen on one device aren't new on another at its next refresh."
                     : "Saved posts stay on this device until iCloud is ready, then sync through your private iCloud database with your other devices and the Royal desktop browser extension.")
            }
        }
    }
}
