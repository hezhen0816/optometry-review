import SwiftUI
import UIKit

/// Design tokens from the mockups. Dark variants are lightened to keep contrast.
enum Palette {
    static let ink = dynamic(0x15211F, 0xE8EEEC)
    static let muted = dynamic(0x55625F, 0xA3B0AD)
    static let ground = dynamic(0xF3F5F4, 0x0F1715)
    static let card = dynamic(0xFFFFFF, 0x1B2624)
    static let accent = dynamic(0x1D5C73, 0x6FB3CC)
    static let accentSoft = dynamic(0xE2EDF1, 0x1D3640)
    static let warn = dynamic(0xA3461A, 0xF09A6E)
    static let warnSoft = dynamic(0xFBEEE6, 0x3D2418)
    static let chart = dynamic(0x13739A, 0x5CB8DC)
    static let notice = dynamic(0xFFF4D6, 0x3A3018)
    static let noticeInk = dynamic(0x6B4A00, 0xF2D27A)
    /// 還不穩 label of a 考點 (text on its soft background).
    static let shaky = dynamic(0x6B4A00, 0xF2D27A)
    static let shakySoft = dynamic(0xFFF4D6, 0x3A3018)
    static let hairline = dynamic(0xE4E9E7, 0x2A3633)
    static let border = dynamic(0xDCE2E0, 0x34413E)
    static let chipBorder = dynamic(0xB7C2BF, 0x4A5754)
    static let badge = dynamic(0xEEF2F1, 0x26322F)
    static let segmentTrack = dynamic(0xE4E9E7, 0x26322F)
    static let coach = dynamic(0x15211F, 0x2C3A37)
    /// Recessed light-gray box inside a question (the 「前題」 block).
    static let inset = dynamic(0xE8ECEB, 0x222D2B)
    /// Stronger outline for standalone controls (onboarding date field, stepper buttons).
    static let controlBorder = dynamic(0x6B7774, 0x8A9693)
    /// Dimming and shadows; stays dark in both modes.
    static let scrim = Color(UIColor(hex: 0x15211F))
    /// Text on the white 「知道了」 pill of coach tips; the pill stays white in both modes, so the ink is fixed.
    static let onCoachPill = Color(UIColor(hex: 0x15211F))
    /// Fixed (same in both modes) fills for white-text hero cards, and the pass / fail ink on their white capsule.
    static let heroFill = Color(UIColor(hex: 0x1D5C73))
    static let heroWarn = Color(UIColor(hex: 0xA3461A))
    /// Ink, muted text and chip fill on surfaces that stay white in both modes (figure viewer).
    static let onWhiteInk = Color(UIColor(hex: 0x15211F))
    static let onWhiteMuted = Color(UIColor(hex: 0x55625F))
    static let onWhiteChip = Color(UIColor(hex: 0xEEF2F1))
    /// Text on the accent background. In dark mode accent is light, so text turns dark.
    static let onAccent = dynamic(0xFFFFFF, 0x0F1715)
    /// Text on the warn background (dark warn is light orange, so text turns dark).
    static let onWarn = dynamic(0xFFFFFF, 0x0F1715)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Fixed mockup sizes scaled with Dynamic Type.
struct AppFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let style: UIFont.TextStyle

    func body(content: Content) -> some View {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits)
        return content.font(.system(size: scaled, weight: weight, design: design))
    }
}

extension View {
    func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default,
                 relativeTo style: UIFont.TextStyle = .body) -> some View {
        modifier(AppFont(size: size, weight: weight, design: design, style: style))
    }

    /// Serif heading per mockup (system New York; CJK falls back to the system font).
    func headingFont(_ size: CGFloat = 32) -> some View {
        appFont(size, .bold, design: .serif, relativeTo: .largeTitle)
    }
}

extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 54
    var inverted = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(17, .bold)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(inverted ? Palette.accent : Palette.onAccent)
            .background(RoundedRectangle(cornerRadius: 14).fill(inverted ? Palette.card : Palette.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(16, .bold)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(Palette.accent)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Small rounded tag used above question stems.
struct Chip: View {
    enum Kind { case subject, plain, notice }
    let text: String
    var kind: Kind = .plain

    var body: some View {
        Text(text)
            .appFont(12, kind == .plain ? .regular : .bold, relativeTo: .caption1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
    }

    private var fg: Color {
        switch kind {
        case .subject: Palette.accent
        case .plain: Palette.muted
        case .notice: Palette.noticeInk
        }
    }

    private var bg: Color {
        switch kind {
        case .subject: Palette.accentSoft
        case .plain: Palette.card
        case .notice: Palette.notice
        }
    }
}

enum Haptics {
    /// 設定「震動回饋」; on unless turned off.
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.hapticsEnabled) as? Bool ?? true
    }

    static func selection() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// One soft tap when a practice answer is graded; the success/warning patterns felt like a buzz on every question.
    static func answer() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
    }
    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

enum DateText {
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d"
        return f
    }()

    static let longMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M 月 d 日"
        return f
    }()

    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "yyyy/M/d"
        return f
    }()

    static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// "今天" / "明天" / "3 天後" for the next review.
    static func nextReview(_ due: Date?, now: Date = .now) -> String {
        guard let due else { return "" }
        return nextReview(days: daysBetween(now, due))
    }

    static func nextReview(days: Int) -> String {
        if days <= 0 { return "今天" }
        if days == 1 { return "明天" }
        return "\(days) 天後"
    }
}

/// Motion helpers honoring Reduce Motion.
enum Motion {
    static func questionTransition(reduce: Bool) -> AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal: .move(edge: .leading).combined(with: .opacity))
    }

    /// Forward: old question leaves to the left; backward: it leaves to the right.
    static func questionTransition(reduce: Bool, forward: Bool) -> AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    static func questionAnimation(reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.28)
    }

    /// Color-only change of answer options after answering (spec: 0.2 s). Layout is never animated.
    static let answerReveal: Animation = .easeInOut(duration: 0.2)

    static func sheetAnimation(reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85)
    }
}

/// Segmented control in the mockup style (grey track, white selected pill).
struct SegmentPicker: View {
    let options: [String]
    @Binding var selection: String
    var height: CGFloat = 40
    /// Optional display text per option (e.g. "只看錯題 16").
    var label: (String) -> String = { $0 }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    guard !on else { return }
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(label(option)).appFont(14, on ? .bold : .regular, relativeTo: .subheadline)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Palette.card : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.segmentTrack))
    }
}

/// Small rounded badge used in lists ("有更正", "可用計算器").
struct TagBadge: View {
    let text: String
    var notice = false

    var body: some View {
        Text(text)
            .appFont(11, notice ? .bold : .regular, relativeTo: .caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(notice ? Palette.noticeInk : Palette.ink)
            .background(RoundedRectangle(cornerRadius: 6).fill(notice ? Palette.notice : Palette.badge))
            .fixedSize()
    }
}

/// Back button used by custom top bars: chevron plus the name of the screen it returns to.
struct BackButton: View {
    /// 「返回錯題本」: VoiceOver label; the visible title drops the 「返回」 prefix.
    var label = "返回"
    let action: () -> Void

    static func title(_ label: String) -> String {
        label.hasPrefix("返回") && label.count > 2 ? String(label.dropFirst(2)) : label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                Text(Self.title(label)).appFont(16, .medium).lineLimit(1)
            }
            .foregroundStyle(Palette.accent)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Dark status toast with an optional trailing action (「已移出複習 ・ 查看」).
struct Toast: View {
    let text: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(text).appFont(14, relativeTo: .subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle).appFont(14, .bold, relativeTo: .subheadline)
                        .foregroundStyle(Palette.dynamic(0xB9D7E3, 0x1D5C73))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Palette.dynamic(0xFFFFFF, 0x0F1715))
        .padding(.leading, 16)
        .padding(.trailing, actionTitle == nil ? 16 : 8)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.dynamic(0x15211F, 0xE8EEEC)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - iPad width

enum Layout {
    /// Widest a phone-style screen's scroll content gets (margins included); wider screens center it.
    static let readableWidth: CGFloat = 720
    /// Wider column for iPad landscape (window at least `threeColumnWidth`), so single-column pages do not float in
    /// a sea of margin.
    static let readableWideWidth: CGFloat = 860

    static func readableWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth >= threeColumnWidth ? readableWideWidth : readableWidth
    }
    /// Widest a first-visit tip bubble gets (iPad); phones use the screen width minus margins.
    static let coachBubbleWidth: CGFloat = 420
    /// From this window width the 講義 page shows its three columns (iPad landscape).
    static let threeColumnWidth: CGFloat = 1000

    /// Two-column answer layout (question left, AI 解析 right): iPad landscape only; portrait stays single-column.
    static func isWideAnswerLayout(_ size: CGSize) -> Bool {
        size.width >= threeColumnWidth && size.width > size.height
    }
}

/// Keeps a vertical ScrollView's content in a centered column on wide screens (iPad); no effect on iPhone widths.
/// The scroll view itself stays full width, so it still scrolls from anywhere on the screen.
private struct ReadableScrollWidth: ViewModifier {
    /// The margin is computed from the proposed width in a single layout pass. An earlier version measured the scroll
    /// view into @State and fed it back into contentMargins; on iPad portrait (810pt) that never settled and froze
    /// the main thread (tour pages).
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .contentMargins(.horizontal, max(0, ((proxy.size.width - Layout.readableWidth(for: proxy.size.width)) / 2).rounded(.down)), for: .scrollContent)
        }
    }
}

extension View {
    /// Content of a bottom-pinned bar (buttons, answer sheet): same readable column as the scroll content on wide
    /// screens, so the buttons do not stretch across an iPad. Put it after the horizontal padding and before the
    /// bar's background, which keeps spanning the full width. No effect on iPhone widths.
    func readableBarWidth() -> some View {
        containerRelativeFrame(.horizontal) { width, _ in min(width, Layout.readableWidth(for: width)) }
            .frame(maxWidth: .infinity)
    }

    /// Put on a vertical ScrollView whose content is laid out for a phone.
    func readableScrollWidth() -> some View { modifier(ReadableScrollWidth()) }
}
