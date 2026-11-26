import SwiftUI

/// Wrapping horizontal layout for chips.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, maxWidth)
            if x > 0, x + w > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, bounds.width)
            if x > bounds.minX, x + w > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Reports a view's height to a binding.
private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func readHeight(_ binding: Binding<CGFloat>) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: HeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(HeightKey.self) { binding.wrappedValue = $0 }
    }
}
