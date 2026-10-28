import SwiftUI

// Bottom navigation split into three pieces: a Hacker News/Reddit pill, the All
// crown on its own, and a YouTube/Settings pill. Replaces the system tab bar,
// which can't be split this way. Icons only; labels are for VoiceOver.
struct TabPills: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 10) {
            pill {
                item(.hn, "Hacker News") { Image(systemName: "y.square") }
                item(.reddit, "Reddit") { RedditGlyph().frame(width: 26, height: 24) }
            }
            Button { selection = .all } label: {
                Image(systemName: selection == .all ? "crown.fill" : "crown")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .all ? Color.accentColor : .primary)
            .glassBackground(Circle())
            .accessibilityLabel("All")
            .accessibilityAddTraits(selection == .all ? .isSelected : [])
            pill {
                item(.youtube, "YouTube") { Image(systemName: "play.rectangle") }
                item(.settings, "Settings") { Image(systemName: "gearshape") }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(4)
            .glassBackground(Capsule())
    }

    private func item<Icon: View>(_ tab: AppTab, _ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selection = tab } label: {
            icon()
                .font(.title2)
                .frame(width: 56, height: 48)
                .background {
                    if selection == tab {
                        Capsule().fill(.primary.opacity(0.1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == tab ? Color.accentColor : .primary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
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
