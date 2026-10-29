import SwiftUI

// Tab bar icons the system tab bar can't make from a plain SF Symbol name.
@MainActor
enum TabIcons {
    // The app icon's crown as a template image, so the tab bar tints it like the other
    // tabs: the app's gold when selected. Drawn larger than the other icons so it
    // stands out.
    static let crown: UIImage = {
        let width: CGFloat = 44
        let renderer = ImageRenderer(content: RoyalCrown()
            .fill(.black)
            .frame(width: width, height: width / RoyalCrown.aspectRatio))
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }()

    // RedditGlyph rendered once as a template image, so the tab bar tints it
    // like the other icons.
    static let reddit: UIImage = {
        let renderer = ImageRenderer(content: RedditGlyph().frame(width: 32, height: 30).foregroundStyle(.black))
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }()
}

// The crown from the app icon: two side points and a diamond center over a separate
// band. Traced on the icon's 1024×1024 grid and scaled from its bounds to fit.
struct RoyalCrown: Shape {
    private static let bounds = CGRect(x: 200, y: 250, width: 624, height: 520)
    static let aspectRatio = bounds.width / bounds.height

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Left half, from the bottom-left corner of the crown up to its top point.
        path.move(to: CGPoint(x: 310, y: 640))
        path.addArc(tangent1End: CGPoint(x: 183, y: 305), tangent2End: CGPoint(x: 395, y: 467), radius: 40)
        path.addLine(to: CGPoint(x: 395, y: 467))
        path.addQuadCurve(to: CGPoint(x: 480, y: 460), control: CGPoint(x: 440, y: 505))
        path.addQuadCurve(to: CGPoint(x: 485, y: 410), control: CGPoint(x: 500, y: 435))
        path.addArc(tangent1End: CGPoint(x: 440, y: 350), tangent2End: CGPoint(x: 512, y: 252), radius: 14)
        path.addArc(tangent1End: CGPoint(x: 512, y: 252), tangent2End: CGPoint(x: 584, y: 350), radius: 16)
        // Right half, the mirror image.
        path.addArc(tangent1End: CGPoint(x: 584, y: 350), tangent2End: CGPoint(x: 539, y: 410), radius: 14)
        path.addLine(to: CGPoint(x: 539, y: 410))
        path.addQuadCurve(to: CGPoint(x: 544, y: 460), control: CGPoint(x: 524, y: 435))
        path.addQuadCurve(to: CGPoint(x: 629, y: 467), control: CGPoint(x: 584, y: 505))
        path.addArc(tangent1End: CGPoint(x: 841, y: 305), tangent2End: CGPoint(x: 714, y: 640), radius: 40)
        path.addLine(to: CGPoint(x: 714, y: 640))
        path.closeSubpath()
        // The band below.
        path.addRoundedRect(in: CGRect(x: 310, y: 668, width: 404, height: 92), cornerSize: CGSize(width: 30, height: 30))

        let bounds = Self.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return path.applying(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
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
