import AVFoundation
import SwiftUI

@main
struct RoyalApp: App {
    init() {
        // Play video sound even with the silent switch on, and keep picture-in-picture going.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Installs from before the setup card have already loaded the All feed; skip the card.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preference.setupComplete) == nil && defaults.object(forKey: "allFeedRefreshedAt") != nil {
            defaults.set(true, forKey: Preference.setupComplete)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
