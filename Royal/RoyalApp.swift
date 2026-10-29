import AVFoundation
import SwiftUI

@main
struct RoyalApp: App {
    init() {
        // Play video sound even with the silent switch on, and keep picture-in-picture going.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
