import SwiftUI
import SwiftData

/// 練習範圍 for the 今日 plan: narrows new questions only; due mistakes are never filtered.
struct ScopePickerSheet: View {
    let initial: PracticeScope
    let onApply: (PracticeScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false

    @State private var draft = PracticeScope.all
    @State private var accuracy: [String: UnitAccuracy.Rate] = [:]
    @State private var loaded = false

    var body: some View {
        let pool = bank.reviewPool(includeSpecial: includeSpecial)
        var noUnits = draft
        noUnits.units = []
        let inYears = noUnits.filter(pool)
        let counts = Dictionary(grouping: inYears.compactMap(\.primaryConcept), by: { $0 }).mapValues(\.count)
        return ScopeSheet(title: "練習範圍", subtitle: "錯題複習不受範圍限制", onClose: { dismiss() }, trailing: {
            SheetResetButton { draft = .all }
        }) {
            ScopeField(title: "科目") {
                SubjectChoice(subject: Binding(get: { draft.subject }, set: { draft.setSubject($0) }))
            }
            ScopeField(title: "年份") {
                YearChoice(selection: $draft.years, years: bank.availableYears)
            }
            UnitChoice(subject: draft.subject, units: draft.subject.map(bank.units(of:)) ?? [],
                       selected: $draft.units, counts: counts, accuracy: accuracy)
        } footer: {
            ScopeCountLine(prefix: "範圍內共", count: draft.filter(pool).count)
            Button("套用") {
                Haptics.selection()
                onApply(draft)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
        }
        .trackScreen("scope")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = initial
            draft.years = initial.years.normalized(years: bank.availableYears)
            accuracy = UnitAccuracy.compute(attempts: StudyStore(context: context).allAttempts().map { ($0.questionID, $0.correct) },
                                            bank: bank)
        }
    }
}

/// Opens 自選練習 with a prefilled choice.
struct CustomPracticeRequest: Identifiable {
    let id = UUID()
    let choice: CustomPracticeChoice

    /// The last kind and size as remembered, in today's 練習範圍.
    static func today() -> CustomPracticeRequest {
        var choice = ScopeStore.custom()
        choice.scope = ScopeStore.daily()
        return CustomPracticeRequest(choice: choice)
    }

    /// A shortcut: subject, optional single year, units and kind; anything else cleared, size kept.
    static func shortcut(subject: String?, year: Int? = nil, units: Set<String> = [],
                         kind: CustomPracticeChoice.Kind) -> CustomPracticeRequest {
        var choice = ScopeStore.custom()
        choice.scope = PracticeScope(subject: subject,
                                     years: year.map { YearSelection(mode: .single, from: $0, to: $0) } ?? .all,
                                     units: units)
        choice.kind = kind
        return CustomPracticeRequest(choice: choice)
    }
}

/// 自選練習: pick subject, kind, size, years and units, then practice untimed with the usual answer sheet.
struct CustomPracticeSheet: View {
    let initial: CustomPracticeChoice
    let onStart: (CustomPracticeChoice, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @Environment(AppRouter.self) private var router: AppRouter?

    @State private var draft = CustomPracticeChoice()
    @State private var history = CustomPractice.History()
    @State private var accuracy: [String: UnitAccuracy.Rate] = [:]
    @State private var loaded = false

    private static let customLabel = "自訂"
    private static let allLabel = "全部"
    /// 「<每天想做幾題> 題」／自訂／全部 (全部 last, like every segment).
    private var sizeLabels: [String] { ["\(dailyGoal) 題", Self.customLabel, Self.allLabel] }
    /// 「自訂」 stays selected while the stepper passes the daily goal.
    @State private var customMode = false

    var body: some View {
        let pool = bank.reviewPool(includeSpecial: includeSpecial)
        let matched = CustomPractice.matches(pool: pool, choice: draft, history: history).count
        let take = draft.take(matched, goal: dailyGoal)
        return ScopeSheet(title: "自選練習", subtitle: "不計時，每題答完就看解答", onClose: { dismiss() }) {
            SheetResetButton {
                draft = CustomPracticeChoice()
                customMode = false
            }
        } fields: {
            ScopeField(title: "科目") {
                SubjectChoice(subject: Binding(get: { draft.scope.subject }, set: { draft.scope.setSubject($0) }))
            }
            ScopeField(title: "題目") {
                SegmentPicker(options: CustomPracticeChoice.Kind.allCases.map(\.label),
                              selection: Binding(get: { draft.kind.label }, set: { label in
                                  draft.kind = CustomPracticeChoice.Kind.allCases.first { $0.label == label } ?? draft.kind
                              }), height: 44)
            }
            ScopeField(title: "題數") {
                VStack(spacing: 8) {
                    SegmentPicker(options: sizeLabels, selection: sizeSelection, height: 44)
                    if customMode {
                        customStepper(matched: matched).transition(.opacity)
                    }
                }
            }
            ScopeField(title: "年份") {
                YearChoice(selection: $draft.scope.years, years: bank.availableYears)
            }
            UnitChoice(subject: draft.scope.subject, units: draft.scope.subject.map(bank.units(of:)) ?? [],
                       selected: $draft.scope.units,
                       counts: CustomPractice.unitCounts(pool: pool, choice: draft, history: history),
                       accuracy: accuracy,
                       onOverview: router.map { r in { dismiss(); r.openUnitOverview() } })
        } footer: {
            (Text("符合 ") + Text("\(matched)").bold().foregroundColor(Palette.ink) + Text(" 題")
             + Text(matched > 0 && take < matched ? "，這次練 \(take) 題" : ""))
                .appFont(13, relativeTo: .footnote)
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
            if matched > 0 {
                Button("開始練習") {
                    var rng = SystemRandomNumberGenerator()
                    let queue = CustomPractice.queue(pool: pool, choice: draft, history: history, goal: dailyGoal,
                                                     using: &rng)
                    guard !queue.isEmpty else { return }
                    Haptics.selection()
                    onStart(draft, queue)
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))
            } else {
                Button("沒有符合的題目") {}
                    .buttonStyle(DisabledFooterButtonStyle())
                    .disabled(true)
            }
        }
        .trackScreen("customPractice")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = initial.normalized(goal: dailyGoal)
            customMode = draft.isCustomSize
            draft.scope.years = initial.scope.years.normalized(years: bank.availableYears)
            let store = StudyStore(context: context)
            history = store.practiceHistory()
            accuracy = UnitAccuracy.compute(attempts: store.allAttempts().map { ($0.questionID, $0.correct) }, bank: bank)
        }
    }
}

extension CustomPracticeSheet {
    private var sizeSelection: Binding<String> {
        Binding(get: {
            if customMode { return Self.customLabel }
            return draft.size == 0 ? Self.allLabel : sizeLabels[0]
        }, set: { label in
            if label == Self.customLabel {
                customMode = true
                if !draft.isCustomSize { draft.size = CustomPracticeChoice.customDefault }
            } else {
                customMode = false
                draft.size = label == Self.allLabel ? 0 : CustomPracticeChoice.goalSize
            }
        })
    }

    /// Compact 5–200 stepper; capped at the matches so it never offers more than the footer can practice.
    private func customStepper(matched: Int) -> some View {
        let upper = CustomPracticeChoice.customUpper(matched: matched)
        let value = Binding(get: { min(max(draft.size, CustomPracticeChoice.customRange.lowerBound), upper) },
                            set: { draft.size = $0 })
        return Stepper(value: value, in: CustomPracticeChoice.customRange.lowerBound...upper,
                       step: CustomPracticeChoice.customStep) {
            Text("每次 \(value.wrappedValue) 題").appFont(15).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .accessibilityValue("\(value.wrappedValue) 題")
    }
}

/// Presents 自選練習 for a request, then its session full screen once the sheet is gone.
private struct CustomPracticeLauncher: ViewModifier {
    @Binding var request: CustomPracticeRequest?
    let onFinish: () -> Void
    @State private var pending: SessionRequest?
    @State private var session: SessionRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $request, onDismiss: {
                guard let p = pending else { return }
                pending = nil
                session = p
            }) { req in
                CustomPracticeSheet(initial: req.choice) { choice, queue in
                    ScopeStore.setCustom(choice)
                    pending = SessionRequest(queue: queue, doneBefore: 0, isDaily: false, isCustom: true)
                    request = nil
                }
            }
            .fullScreenCover(item: $session, onDismiss: onFinish) { req in
                ReviewSessionView(request: req)
            }
    }
}

extension View {
    /// Attaches 自選練習: set `request` to open the sheet; `onFinish` runs after the session closes.
    func customPractice(_ request: Binding<CustomPracticeRequest?>, onFinish: @escaping () -> Void = {}) -> some View {
        modifier(CustomPracticeLauncher(request: request, onFinish: onFinish))
    }
}

/// Grey footer button shown when nothing can start.
private struct DisabledFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(17, .bold)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.border))
    }
}
