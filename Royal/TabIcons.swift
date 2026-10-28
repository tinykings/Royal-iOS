import SwiftUI

// Tab bar icons the system tab bar can't make from a plain SF Symbol name.
@MainActor
enum TabIcons {
    // The tab bar tints template images itself, so the crown is drawn with its
    // own color baked in to stay gold whether or not All is selected.
    static func crown(selected: Bool) -> UIImage {
        let image = UIImage(systemName: selected ? "crown.fill" : "crown") ?? UIImage()
        return image.withTintColor(UIColor(Color.royalGold), renderingMode: .alwaysOriginal)
    }

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
    static let royalGold = Color(red: 0.85, green: 0.65, blue: 0.13)
}

extension View {
    // Liquid Glass where available, a blurred material before iOS 26.
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
