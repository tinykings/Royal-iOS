import SwiftUI

// Turns saved-post sync with the desktop extension on and off, and shows how it's going.
struct SavedSyncView: View {
    @EnvironmentObject private var store: FeedStore
    @ObservedObject var sync: SavedSync

    var body: some View {
        List {
            Section {
                Text("Sync saved posts with the Royal desktop extension through your private iCloud database. Seen posts and the All feed don't sync yet.")
            }
            if let identifier = SavedSync.containerIdentifier {
                Section {
                    Toggle("Sync Saved Posts", isOn: Binding(
                        get: { sync.isOn },
                        set: { on in
                            if on { Task { await store.enableSavedSync() } } else { sync.disable() }
                        }))
                        .disabled(sync.busy && !sync.isOn)
                    if sync.isOn {
                        LabeledContent("Pending changes", value: "\(sync.library.pendingCount)")
                        if let last = sync.library.lastSync {
                            LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened))
                        }
                        Button("Sync Now") { Task { await sync.sync() } }
                            .disabled(sync.busy)
                    }
                } footer: {
                    Text("Use the same Apple Account as the desktop, with its sync turned on in the same environment (\(SavedSync.environment)). Turning sync on adds the posts saved here, but a post already unsaved on another device stays unsaved. Turn it on on each iPhone and iPad.")
                }
                Section("CloudKit") {
                    LabeledContent("Container", value: identifier)
                    LabeledContent("Environment", value: SavedSync.environment)
                }
            } else {
                Section("Setup required") {
                    Text("CloudKit is not configured for this build. See desktop/README.md in the repository for setup.")
                }
            }
            if !sync.status.isEmpty {
                Section { Text(sync.status).textSelection(.enabled) }
            }
        }
        .navigationTitle("Sync Saved Posts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
