import SwiftUI
import WebKit

// Docked player above the tabs: the video at 16:9 with a bar below naming it and
// closing it. In landscape it fills the screen, with the close button in the margin
// beside the video. Both keep clear of YouTube's own controls (tap the video), which
// handle fullscreen and the rest. The web view stays alive across both, so playback
// continues while feeds scroll and tabs switch.
struct VideoPanel: View {
    @EnvironmentObject private var store: FeedStore
    let post: FeedPost
    let expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            YouTubePlayer(videoId: post.videoId ?? "")
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil)
            if !expanded {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(post.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Playing \(post.title), \(post.label)")
                    Spacer(minLength: 0)
                    closeButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
        // The video centers across the whole width, leaving margins for the close button.
        .ignoresSafeArea(edges: expanded ? .horizontal : [])
        .overlay(alignment: .topTrailing) {
            if expanded {
                closeButton
                    .foregroundStyle(.white)
                    .padding(12)
                    .ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(expanded)
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark") {
            store.playingVideo = nil
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .frame(width: 32, height: 32)
        .background(Color.secondary.opacity(0.25), in: Circle())
        .contentShape(Circle())
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
