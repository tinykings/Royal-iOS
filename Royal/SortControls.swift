import SwiftUI

// Icon-only header toggle styled to match the tab bar's glass pills. Built by hand
// rather than as a segmented Picker so a segment can open a menu (Reddit's Top).
struct IconSegments<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(3)
            .glassBackground(Capsule())
    }
}

struct IconSegmentLabel: View {
    let icon: String
    let title: String
    let selected: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.body)
            .frame(width: 42, height: 32)
            .background {
                if selected {
                    Capsule().fill(.primary.opacity(0.1))
                }
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .contentShape(Capsule())
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct IconSegment: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconSegmentLabel(icon: icon, title: title, selected: selected)
        }
        .buttonStyle(.plain)
    }
}

enum RedditTimeframe: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        }
    }
}
