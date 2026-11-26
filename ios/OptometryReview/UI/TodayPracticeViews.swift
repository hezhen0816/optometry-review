import SwiftUI

/// 今日練習 sheet: today's correct count against the goal, the plan's counts, scope, goal and new-question ratio.
struct TodayPracticeSheet: View {
    let summary: TodaySummary?
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(ScopeStore.dailyKey) private var dailyScopeRaw = ""
    @AppStorage(SettingsKey.newRatioMode) private var ratioRaw = SettingsKey.defaultNewRatioMode
    @AppStorage(SettingsKey.customNewPercent) private var customPercent = SettingsKey.defaultCustomNewPercent

    @State private var showScope = false
    @State private var showRatio = false

    private var correct: Int { summary?.correctToday ?? 0 }

    var body: some View {
        ScopeSheet(title: "今日練習", subtitle: "", onClose: { dismiss() }) {
            ring
                .frame(maxWidth: .infinity)
            countsCard
            subjectDueCard
            settingsCard
        } footer: {
            Button("開始練習") {
                Haptics.selection()
                onStart()
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
            .disabled(bank.questions.isEmpty)
        }
        .trackScreen("todayPractice")
        .sheet(isPresented: $showScope) {
            ScopePickerSheet(initial: ScopeStore.daily()) { ScopeStore.setDaily($0) }
        }
        .sheet(isPresented: $showRatio) {
            RatioSheet(goal: dailyGoal)
        }
    }

    private var ring: some View {
        let fraction = dailyGoal > 0 ? min(1, Double(correct) / Double(dailyGoal)) : 0
        return ZStack {
            Circle().stroke(Palette.border, lineWidth: 10)
            Circle().trim(from: 0, to: fraction)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(correct)").appFont(38, .bold, relativeTo: .largeTitle).monospacedDigit()
                    Text("/ \(dailyGoal)").appFont(17).monospacedDigit().foregroundStyle(Palette.muted)
                }
                Text("今天答對").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 136, height: 136)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今天答對 \(correct) 題，目標 \(dailyGoal) 題")
    }

    private var countsCard: some View {
        VStack(spacing: 0) {
            countRow("新題", summary?.plan.newIDs.count ?? 0, color: Palette.accent, divider: true)
            countRow("待複習", summary?.reviewOnlyDueCount ?? 0, color: HeatRamp.fills[2], divider: true)
            countRow("再次挑戰", summary?.retryCount ?? 0, color: Palette.warn, divider: false, emphasized: true)
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    /// 各科待複習 (moved here from the 今日 page): the same items as 待複習 + 再次挑戰 above, by subject.
    private var subjectDueCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("各科待複習").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.muted)
                .padding(.top, 12).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(Subjects.all.enumerated()), id: \.offset) { idx, name in
                let n = summary?.reviewBySubject[name] ?? 0
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(name).appFont(15)
                        Spacer()
                        Text("\(n) 題").appFont(15, .bold).monospacedDigit()
                            .foregroundStyle(n >= 5 ? Palette.warn : (n == 0 ? Palette.muted : Palette.ink))
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    if idx < Subjects.all.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func countRow(_ title: String, _ n: Int, color: Color, divider: Bool, emphasized: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                Text(title).appFont(15)
                Spacer()
                Text("\(n)").appFont(15, .bold).monospacedDigit()
                    .foregroundStyle(emphasized && n > 0 ? Palette.warn : Palette.ink)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }

    private var settingsCard: some View {
        _ = dailyScopeRaw
        let scope = ScopeStore.daily()
        let scopeLabel = scope.label { bank.unitByID[$0]?.name }
        // The scope only narrows new questions; due mistakes and 再練一次 ignore it.
        let scopeNote = scope.isAll ? nil : "錯題複習不受範圍限制"
        return VStack(spacing: 0) {
            Button {
                Haptics.selection()
                showScope = true
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("範圍").appFont(15)
                        if let scopeNote {
                            Text(scopeNote).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: 8)
                    Text(scopeLabel).appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                    Text("更改").appFont(14, .bold, relativeTo: .subheadline).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 8)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("範圍：\(scopeLabel)\(scopeNote.map { "，\($0)" } ?? "")。更改")
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 4) {
                Text("每日題數").appFont(15)
                Spacer()
                stepButton("minus", label: "減 5 題") {
                    dailyGoal = max(SettingsKey.dailyGoalRange.lowerBound, dailyGoal - SettingsKey.dailyGoalStep)
                }
                .disabled(dailyGoal <= SettingsKey.dailyGoalRange.lowerBound)
                Text("\(dailyGoal)").appFont(17, .bold).monospacedDigit()
                    .frame(minWidth: 36)
                    .contentTransition(.numericText())
                stepButton("plus", label: "加 5 題") {
                    dailyGoal = min(SettingsKey.dailyGoalRange.upperBound, dailyGoal + SettingsKey.dailyGoalStep)
                }
                .disabled(dailyGoal >= SettingsKey.dailyGoalRange.upperBound)
            }
            .frame(minHeight: 52)
            .padding(.trailing, -8)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Button {
                Haptics.selection()
                showRatio = true
            } label: {
                HStack(spacing: 10) {
                    Text("新題比例").appFont(15)
                    Spacer()
                    Text(RatioSheet.label(mode: NewRatioMode(rawValue: ratioRaw) ?? .normal, percent: customPercent))
                        .appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.badge))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension TodaySummary {
    /// Due reviews that are not also today's retries (the 待複習 count beside 再次挑戰).
    var reviewOnlyDueCount: Int {
        let retries = Set(retryIDs)
        return plan.dueIDs.filter { !retries.contains($0) }.count
    }
}

/// 新題比例: 普通 (at least 25% new) or 自訂 (slider, or 只複習), with a short Q&A.
struct RatioSheet: View {
    let goal: Int

    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var percent = SettingsKey.defaultCustomNewPercent
    @State private var reviewOnly = false
    @State private var loaded = false

    static func label(mode: NewRatioMode, percent: Int) -> String {
        switch mode {
        case .normal: return "普通"
        case .custom: return "自訂 \(NewRatioMode.normalizedPercent(percent))%"
        case .reviewOnly: return "只複習"
        }
    }

    var body: some View {
        ScopeSheet(title: "新題比例", subtitle: "", onClose: { dismiss() }) {
            SegmentPicker(options: ["普通", "自訂"], selection: Binding(get: { custom ? "自訂" : "普通" },
                                                                    set: { custom = $0 == "自訂" }), height: 44)
            if custom { customCard } else { normalCard }
            faq
        } footer: {
            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(height: 52, inverted: true))
                Button("確認") {
                    Haptics.selection()
                    save()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))
            }
        }
        .trackScreen("newRatio")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let mode = NewRatioMode.value()
            custom = mode != .normal
            reviewOnly = mode == .reviewOnly
            percent = NewRatioMode.customPercent()
        }
    }

    private var normalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("即使今天還有要複習的錯題，也會出現至少 25% 的新題。")
                .appFont(15).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            example("每日 \(goal) 題時，至少 \(DailyPlanner.newQuota(goal: goal, mode: .normal)) 題是新題。")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private var customCard: some View {
        let shown = reviewOnly ? 0 : percent
        let n = DailyPlanner.newQuota(goal: goal, mode: .custom, customPercent: percent)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                (Text("複習 ") + Text("\(100 - shown)%").font(.system(size: 17, weight: .bold)).foregroundColor(Palette.ink))
                Spacer()
                (Text("新題 ") + Text("\(shown)%").font(.system(size: 17, weight: .bold)).foregroundColor(Palette.accent))
            }
            .appFont(14, relativeTo: .subheadline)
            .foregroundStyle(Palette.muted)
            .monospacedDigit()
            .opacity(reviewOnly ? 0.4 : 1)
            .accessibilityHidden(true)
            Slider(value: Binding(get: { Double(percent) }, set: { percent = NewRatioMode.normalizedPercent(Int($0.rounded())) }),
                   in: Double(SettingsKey.customNewPercentRange.lowerBound)...Double(SettingsKey.customNewPercentRange.upperBound),
                   step: Double(SettingsKey.customNewPercentStep))
                .tint(Palette.accent)
                .disabled(reviewOnly)
                .opacity(reviewOnly ? 0.4 : 1)
                .accessibilityLabel("新題比例")
                .accessibilityValue("\(percent)%")
            example(reviewOnly ? "只出待複習與再次挑戰的題。" : "每日 \(goal) 題時，約 \(n) 題是新題。")
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.15)) { reviewOnly.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: reviewOnly ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22))
                        .foregroundStyle(reviewOnly ? Palette.accent : Palette.muted)
                    Text("只複習").appFont(15)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -8)
            .accessibilityAddTraits(reviewOnly ? .isSelected : [])
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func example(_ text: String) -> some View {
        Text(text)
            .appFont(14, relativeTo: .subheadline).lineSpacing(3)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentSoft))
    }

    private var faq: some View {
        VStack(alignment: .leading, spacing: 12) {
            qa("Q. 今天沒做完會怎樣？", "沒練到的錯題會留到明天，先從最容易忘的開始。")
            qa("Q. 答錯的題怎麼辦？", "同一輪隔 3 題會再出一次，答對才算完成；之後照排程再複習。")
        }
        .padding(.horizontal, 4)
    }

    private func qa(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q).appFont(14, .bold, relativeTo: .subheadline)
                .accessibilityAddTraits(.isHeader)
            Text(a).appFont(14, relativeTo: .subheadline).lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        let mode: NewRatioMode = !custom ? .normal : (reviewOnly ? .reviewOnly : .custom)
        d.set(mode.rawValue, forKey: SettingsKey.newRatioMode)
        d.set(NewRatioMode.normalizedPercent(percent), forKey: SettingsKey.customNewPercent)
    }
}
