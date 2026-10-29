import SwiftUI

// Icon-only segmented control for feed headers. A segmented Picker sized to fit
// squeezes icon segments together, so each segment gets a set width instead.
struct HeaderPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [HeaderOption<Value>]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                Image(systemName: option.icon)
                    .accessibilityLabel(option.title)
                    .tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: CGFloat(options.count) * 52)
    }
}

struct HeaderOption<Value: Hashable> {
    let value: Value
    let icon: String
    let title: String
}
