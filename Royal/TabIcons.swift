import SwiftUI

// Tab bar icons the system tab bar can't make from a plain SF Symbol name.
@MainActor
enum TabIcons {
    // A filled crown as a template image, so the tab bar tints it like the other tabs:
    // the app's gold when selected. Drawn at twice the symbol's default size so it
    // stands out from the other tabs.
    static let crown: UIImage = {
        let symbol = UIImage(systemName: "crown.fill") ?? UIImage()
        let rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * 2, height: symbol.size.height * 2))
        let image = UIGraphicsImageRenderer(size: rect.size).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: rect)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    // RedditGlyph rendered once as a template image, so the tab bar tints it
    // like the other icons.
    static let reddit: UIImage = {
        let renderer = ImageRenderer(content: RedditGlyph().frame(width: 32, height: 30).foregroundStyle(.black))
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }()
}

// Simplified Snoo (Reddit's alien) drawn in the current foreground style, since
// SF Symbols has no Reddit logo. Laid out on a 24×24 grid and scaled to fit.
struct RedditGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }

            // Head, ears, antenna and its tip.
            context.fill(Path(ellipseIn: CGRect(x: 2.5, y: 9, width: 19, height: 13)), with: .foreground)
            context.fill(circle(3.6, 11.4, 2.3), with: .foreground)
            context.fill(circle(20.4, 11.4, 2.3), with: .foreground)
            var antenna = Path()
            antenna.move(to: CGPoint(x: 12, y: 9.5))
            antenna.addLine(to: CGPoint(x: 13.6, y: 3.2))
            antenna.addLine(to: CGPoint(x: 17.2, y: 4))
            context.stroke(antenna, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            context.fill(circle(18.6, 4.2, 2), with: .foreground)

            // Eyes and smile cut out of the head.
            context.blendMode = .destinationOut
            context.fill(circle(8.4, 14.6, 1.7), with: .color(.black))
            context.fill(circle(15.6, 14.6, 1.7), with: .color(.black))
            var smile = Path()
            smile.move(to: CGPoint(x: 8.6, y: 18))
            smile.addQuadCurve(to: CGPoint(x: 15.4, y: 18), control: CGPoint(x: 12, y: 20.4))
            context.stroke(smile, with: .color(.black), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    // The app's tint: royal gold, darkened in light mode so buttons, text and the
    // selected tab icon stay readable on white.
    static let royalAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1)
            : UIColor(red: 0.60, green: 0.43, blue: 0, alpha: 1)
    })
}
