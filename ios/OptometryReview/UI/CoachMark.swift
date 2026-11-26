import SwiftUI

/// Dark tip bubble with an arrow pointing at the highlighted element.
struct CoachBubble: View {
    enum ArrowEdge { case top, bottom }

    let title: String
    let message: String
    var arrowEdge: ArrowEdge = .bottom
    var arrowX: CGFloat = 48
    /// False when the bubble is docked away from the highlighted element (nothing to point at).
    var showArrow = true
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appFont(15, .bold)
            Text(message).appFont(14, relativeTo: .subheadline).lineSpacing(4).opacity(0.92)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Text("知道了").appFont(14, .bold)
                    .foregroundStyle(Palette.onCoachPill)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Palette.coach)
                .overlay(alignment: arrowEdge == .bottom ? .bottomLeading : .topLeading) {
                    if showArrow { Rectangle().fill(Palette.coach)
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(45))
                        .offset(x: arrowX, y: arrowEdge == .bottom ? 8 : -8) }
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("提示：\(title)")
    }
}

/// Anchor of the element a coach mark points at.
struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Dim with a cut-out around `rect` and a bubble placed above or below it.
struct CoachSpotlight: View {
    let rect: CGRect
    let size: CGSize
    let title: String
    let message: String
    /// Place the bubble above the highlighted element (arrow on its bottom edge).
    var above = false
    /// Dock the bubble at the bottom of the screen instead of next to the element, so it never covers content near
    /// the element (the element is still cut out of the dim; no arrow).
    var docked = false
    let onClose: () -> Void

    @State private var bubbleHeight: CGFloat = 0

    var body: some View {
        let hole = rect.insetBy(dx: -8, dy: -6)
        let leading: CGFloat = 20
        // Wide screens: a card as wide as a phone would be, placed under/over the element's column (never full width).
        let width = min(size.width - 2 * leading, Layout.coachBubbleWidth)
        let pointX = hole.minX + min(hole.width / 2, 40)
        let x = max(leading, min(size.width - leading - width, pointX - 40))
        let arrowX = max(16, min(width - 32, pointX - x - 8))
        let y = docked ? size.height - bubbleHeight - 110 : (above ? hole.minY - 12 - bubbleHeight : hole.maxY + 12)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size).insetBy(dx: -400, dy: -400))
                p.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10))
            }
            .fill(Palette.scrim.opacity(0.35), style: FillStyle(eoFill: true))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            CoachBubble(title: title, message: message, arrowEdge: above ? .bottom : .top,
                        arrowX: arrowX, showArrow: !docked, onClose: onClose)
                .frame(width: width)
                .readHeight($bubbleHeight)
                .offset(x: docked ? max(leading, (size.width - width) / 2) : x, y: y)
                .opacity(bubbleHeight > 0 ? 1 : 0)
        }
        .transition(.opacity)
    }
}

extension View {
    /// Marks the element a `firstVisitTip` on an ancestor points at.
    func coachTarget() -> some View {
        anchorPreference(key: CoachAnchorKey.self, value: .bounds) { $0 }
    }

    /// A once-only tip (flag `key` in `SettingsKey.allTips`) on the element marked with `coachTarget()`. It appears a
    /// moment after the screen is shown, only while `eligible` and not yet shown; 「知道了」 or a tap on the dim sets the
    /// flag (which syncs to the other devices). One tip per screen.
    func firstVisitTip(key: String, eligible: Bool = true, title: String, message: String,
                       above: Bool = false, docked: Bool = false) -> some View {
        modifier(FirstVisitTip(key: key, eligible: eligible, title: title, message: message, above: above,
                               docked: docked))
    }
}

private struct FirstVisitTip: ViewModifier {
    let eligible: Bool
    let title: String
    let message: String
    let above: Bool
    let docked: Bool
    @AppStorage private var shown: Bool
    @State private var visible = false

    init(key: String, eligible: Bool, title: String, message: String, above: Bool, docked: Bool) {
        self.eligible = eligible
        self.title = title
        self.message = message
        self.above = above
        self.docked = docked
        _shown = AppStorage(wrappedValue: false, key)
    }

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(CoachAnchorKey.self) { anchor in
                GeometryReader { geo in
                    if visible, !shown, let anchor {
                        CoachSpotlight(rect: geo[anchor], size: geo.size, title: title, message: message,
                                       above: above, docked: docked, onClose: close)
                    }
                }
                .ignoresSafeArea()
            }
            .task(id: eligible && !shown) {
                guard eligible, !shown else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.2)) { visible = true } }
            }
    }

    private func close() {
        shown = true
        withAnimation(.easeInOut(duration: 0.2)) { visible = false }
    }
}
