import AVFoundation
import SwiftUI

@main
struct RoyalApp: App {
    init() {
        // Play video sound even with the silent switch on. There is no background audio
        // mode, so playback stops when the app leaves the screen.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Reddit no longer has a New sort; anyone last on it goes back to the default.
        if UserDefaults.standard.string(forKey: Preference.redditSort) == "new" {
            UserDefaults.standard.removeObject(forKey: Preference.redditSort)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
