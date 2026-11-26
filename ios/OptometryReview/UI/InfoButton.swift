import SwiftUI

/// ⓘ button that explains a rule or legend in a popover, so the screen itself stays free of repeated explanations.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).appFont(15, .bold)
                Text(text).appFont(14, relativeTo: .subheadline).lineSpacing(3).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A line of explanation that shows only until the person has seen it once (flag `key` in `SettingsKey.allTips`).
/// The flag is set when the line appears, so it is gone from the next visit on.
struct FirstTimeNote<Content: View>: View {
    @AppStorage private var seen: Bool
    @State private var showNow: Bool
    private let content: Content

    init(key: String, @ViewBuilder content: () -> Content) {
        _seen = AppStorage(wrappedValue: false, key)
        _showNow = State(initialValue: SettingsKey.tipPending(key))
        self.content = content()
    }

    var body: some View {
        if showNow {
            content.onAppear { seen = true }
        }
    }
}
