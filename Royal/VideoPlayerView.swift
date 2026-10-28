import SwiftUI
import WebKit

// Docked player above the tabs: the video at 16:9 with a close button. In landscape
// it fills the screen. YouTube's own controls (tap the video) handle fullscreen and
// the rest. The web view stays alive across both, so playback continues while feeds
// scroll and tabs switch.
struct VideoPanel: View {
    @EnvironmentObject private var store: FeedStore
    let post: FeedPost
    let expanded: Bool
    let collapsedHeight: CGFloat

    var body: some View {
        YouTubePlayer(videoId: post.videoId ?? "")
            .frame(height: expanded ? nil : collapsedHeight)
            .frame(maxHeight: expanded ? .infinity : nil)
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark") {
                    store.playingVideo = nil
                }
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.55), in: Circle())
                .padding(8)
            }
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden(expanded)
    }
}

// Plays YouTube's embed page as the top-level document so it shares the app's
// YouTube login. If the embed fails (blocked embedding, missing-referrer error 153),
// it falls back to the mobile watch page.
struct YouTubePlayer: UIViewRepresentable {
    // Embeds without a referrer fail with error 153, so loads name the project's site.
    private static let referrer = "https://tinykings.github.io/"

    let videoId: String

    func makeCoordinator() -> Coordinator {
        Coordinator(videoId: videoId)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WebProfile.configuration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // YouTube's fullscreen button needs element fullscreen.
        config.preferences.isElementFullscreenEnabled = true
        // The embed page shows its error inside the player; report it so we can fall back.
        config.userContentController.addUserScript(WKUserScript(source: """
            if (location.pathname.startsWith("/embed/")) {
              const check = setInterval(() => {
                const error = document.querySelector(".ytp-error");
                if (error) {
                  clearInterval(check);
                  window.webkit.messageHandlers.playerError.postMessage(error.innerText.slice(0, 200));
                }
              }, 500);
            }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "playerError")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        context.coordinator.webView = webView
        context.coordinator.loadEmbed()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playerError")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let videoId: String
        weak var webView: WKWebView?
        private var fellBack = false

        init(videoId: String) {
            self.videoId = videoId
        }

        func loadEmbed() {
            var components = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
            components.queryItems = [
                URLQueryItem(name: "autoplay", value: "1"),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
                URLQueryItem(name: "origin", value: String(YouTubePlayer.referrer.dropLast())),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(YouTubePlayer.referrer, forHTTPHeaderField: "Referer")
            webView?.load(request)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !fellBack else { return }
            fellBack = true
            #if DEBUG
            NSLog("Royal embed error for %@: %@", videoId, String(describing: message.body))
            #endif
            webView?.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(videoId)")!))
        }
    }
}
