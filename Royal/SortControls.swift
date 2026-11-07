import SwiftUI
import UIKit

// Icon-only segmented control for feed headers. A segmented Picker sized to fit
// squeezes icon segments together, so each segment gets a set width instead.
struct HeaderPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [HeaderOption<Value>]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                icon(for: option)
                    .accessibilityLabel(option.title)
                    .tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: CGFloat(options.count) * 52)
    }

    private func icon(for option: HeaderOption<Value>) -> Image {
        if selection == option.value, let color = option.selectedColor,
           let image = UIImage(systemName: option.selectedIcon ?? option.icon) {
            // Preserve the selected icon's color through the native segmented picker.
            return Image(uiImage: image.withTintColor(color, renderingMode: .alwaysOriginal))
        }
        return Image(systemName: option.icon)
    }
}

struct HeaderOption<Value: Hashable> {
    let value: Value
    let icon: String
    let title: String
    var selectedIcon: String? = nil
    var selectedColor: UIColor? = nil
}
