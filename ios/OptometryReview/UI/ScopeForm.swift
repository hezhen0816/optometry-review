import SwiftUI

/// Bottom-sheet chrome shared by 練習範圍, 自選練習, 年份 and the mistake-book filter:
/// serif title with a subtitle, 重設 (trailing) and close button, scrolling fields, and a footer
/// (count line and one primary button) pinned above the home indicator.
struct ScopeSheet<Fields: View, Footer: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).headingFont(24)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .appFont(13, relativeTo: .footnote)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
                Spacer(minLength: 8)
                trailing()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fields()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            .readableScrollWidth()
            VStack(spacing: 10) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Palette.ground)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }
}

extension ScopeSheet where Trailing == EmptyView {
    init(title: String, subtitle: String, onClose: @escaping () -> Void,
         @ViewBuilder fields: @escaping () -> Fields, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(title: title, subtitle: subtitle, onClose: onClose, trailing: { EmptyView() },
                  fields: fields, footer: footer)
    }
}

/// 「重設」 beside the ✕ of every filter-like sheet.
struct SheetResetButton: View {
    let action: () -> Void

    var body: some View {
        Button("重設") {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        }
        .appFont(15, .medium)
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .buttonStyle(.plain)
    }
}

/// Labelled group inside a scope sheet.
struct ScopeField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(13, .medium, relativeTo: .footnote)
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// Wrapping single-choice chips (科目, 錯因).
struct ChoiceChips: View {
    let options: [String]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(options, id: \.self) { option in
                let on = option == selected
                Button {
                    guard !on else { return }
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.15)) { onPick(option) }
                } label: {
                    Text(option).appFont(14, .medium, relativeTo: .subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(on ? Palette.onAccent : Palette.ink)
                        .background(Capsule().fill(on ? Palette.accent : Palette.card))
                        .overlay(Capsule().strokeBorder(on ? Palette.accent : Palette.chipBorder, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 科目 chips: 全部 plus the five subjects.
struct SubjectChoice: View {
    @Binding var subject: String?

    var body: some View {
        ChoiceChips(options: [MistakeFilter.all] + Subjects.all, selected: subject ?? MistakeFilter.all) { pick in
            subject = pick == MistakeFilter.all ? nil : pick
        }
    }
}

/// 年份: 全部／單一年／範圍 with year menus.
struct YearChoice: View {
    @Binding var selection: YearSelection
    let years: [Int]
    /// Items per year (the mistake-book filter): shown in the menus, years with 0 greyed out.
    var counts: [Int: Int]? = nil
    /// Year picked when switching to 單一年 from 全部; the newest year when nil.
    var singleDefault: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            SegmentPicker(options: YearSelection.Mode.segmentOrder.map(\.label),
                          selection: Binding(get: { selection.mode.label }, set: { label in
                              guard let mode = YearSelection.Mode.segmentOrder.first(where: { $0.label == label }) else { return }
                              var s = selection
                              s.mode = mode
                              if mode == .single, !years.contains(s.from) || selection.mode == .all {
                                  s.from = singleDefault.flatMap { years.contains($0) ? $0 : nil } ?? years.last ?? s.from
                              }
                              selection = s.normalized(years: years)
                          }), height: 44)
            switch selection.mode {
            case .all:
                EmptyView()
            case .single:
                HStack(spacing: 12) {
                    Text("年份").appFont(15)
                    Spacer()
                    yearMenu("年份", value: selection.from, options: years) { y in
                        selection.from = y
                        selection.to = y
                    }
                    .frame(width: 132)
                }
                .yearCard()
            case .range:
                HStack(spacing: 10) {
                    Text("從").appFont(15)
                    yearMenu("起始年份", value: selection.from, options: years) { y in
                        selection.from = y
                        selection.to = max(y, selection.to)
                    }
                    Text("到").appFont(15)
                    yearMenu("結束年份", value: selection.to, options: years) { y in
                        selection.to = y
                        selection.from = min(y, selection.from)
                    }
                }
                .yearCard()
            }
        }
    }

    private func yearMenu(_ label: String, value: Int, options: [Int], set: @escaping (Int) -> Void) -> some View {
        Menu {
            if let counts {
                // Buttons rather than a Picker so empty years can be disabled.
                ForEach(options.reversed(), id: \.self) { y in
                    let n = counts[y] ?? 0
                    Button {
                        Haptics.selection()
                        set(y)
                    } label: {
                        if y == value {
                            Label("\(String(y)) 年　\(n) 題", systemImage: "checkmark")
                        } else {
                            Text("\(String(y)) 年　\(n) 題")
                        }
                    }
                    .disabled(n == 0 && y != value)
                }
            } else {
                Picker(label, selection: Binding(get: { value }, set: { y in
                    Haptics.selection()
                    set(y)
                })) {
                    ForEach(options.reversed(), id: \.self) { Text("\(String($0)) 年").tag($0) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(value)) 年").appFont(15, .bold).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.badge))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(value) 年")
    }
}

private extension View {
    func yearCard() -> some View {
        padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
    }
}

/// 單元 checklist of one subject with counts and the learner's accuracy (below 50 % in orange).
struct UnitChoice: View {
    let subject: String?
    let units: [ConceptUnit]
    @Binding var selected: Set<String>
    let counts: [String: Int]
    let accuracy: [String: UnitAccuracy.Rate]
    /// Header of the count column (題數, 錯題).
    var countTitle = "題數"
    /// Shows 「看單元總覽 ›」 under the list.
    var onOverview: (() -> Void)? = nil

    private static let countWidth: CGFloat = 48
    private static let rateWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("單元").appFont(13, .medium, relativeTo: .footnote)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if subject != nil {
                    Text(countTitle).frame(width: Self.countWidth, alignment: .trailing)
                    Text("正確率").frame(width: Self.rateWidth, alignment: .trailing)
                }
            }
            .appFont(12, relativeTo: .caption1)
            .foregroundStyle(Palette.muted)
            .padding(.leading, 4)
            .padding(.trailing, 16)
            if subject == nil {
                Text("選一科後可挑單元")
                    .appFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            } else {
                VStack(spacing: 0) {
                    row(name: "全部單元", bold: true, on: selected.isEmpty,
                        count: units.reduce(0) { $0 + (counts[$1.id] ?? 0) }, rate: nil, showRate: false) {
                        selected = []
                    }
                    ForEach(units) { unit in
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                        row(name: unit.name, bold: false, on: selected.contains(unit.id),
                            count: counts[unit.id] ?? 0, rate: accuracy[unit.id]?.percent, showRate: true) {
                            var s = PracticeScope(subject: subject, units: selected)
                            s.toggleUnit(unit.id, among: units.map(\.id))
                            selected = s.units
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            }
            if let onOverview {
                Button {
                    Haptics.selection()
                    onOverview()
                } label: {
                    Text("看單元總覽 ›")
                        .appFont(14, .medium, relativeTo: .subheadline)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看單元總覽")
                .accessibilityHint("關閉自選練習，到試題的單元")
            }
        }
    }

    private func row(name: String, bold: Bool, on: Bool, count: Int, rate: Int?, showRate: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.12)) { action() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(on ? Palette.accent : Color.clear)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.onAccent)
                    } else {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.muted.opacity(0.75), lineWidth: 2)
                    }
                }
                .frame(width: 22, height: 22)
                Text(name)
                    .appFont(bold ? 15 : 14, bold ? .bold : .regular)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .appFont(14, relativeTo: .subheadline).monospacedDigit()
                    .foregroundStyle(bold ? Palette.ink : Palette.muted)
                    .frame(width: Self.countWidth, alignment: .trailing)
                Group {
                    if showRate, let rate {
                        Text("\(rate)%")
                            .fontWeight(rate < 50 ? .bold : .regular)
                            .foregroundStyle(rate < 50 ? Palette.warn : Palette.ink)
                    } else if showRate {
                        Text("—").foregroundStyle(Palette.muted)
                    } else {
                        Text("")
                    }
                }
                .appFont(14, relativeTo: .subheadline).monospacedDigit()
                .frame(width: Self.rateWidth, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(name: name, count: count, rate: rate, showRate: showRate))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func accessibility(name: String, count: Int, rate: Int?, showRate: Bool) -> String {
        var text = "\(name)，\(count) 題"
        if showRate { text += rate.map { "，正確率 \($0)%" } ?? "，還沒有作答" }
        return text
    }
}

/// 「範圍內共 N 題」 style footer line.
struct ScopeCountLine: View {
    let prefix: String
    let count: Int
    var suffix = "題"

    var body: some View {
        (Text(prefix + " ") + Text("\(count)").bold().foregroundColor(Palette.ink) + Text(" " + suffix))
            .appFont(13, relativeTo: .footnote)
            .monospacedDigit()
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
    }
}
