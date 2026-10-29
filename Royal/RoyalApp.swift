import AVFoundation
import SwiftUI

@main
struct RoyalApp: App {
    init() {
        // Play video sound even with the silent switch on. There is no background audio
        // mode, so playback stops when the app leaves the screen.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
