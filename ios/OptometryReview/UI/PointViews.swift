import SwiftUI
import SwiftData

/// Navigation value of 講義頁: the unit, and the 考點 to open and scroll to (nil = the weakest one).
struct HandoutRoute: Hashable {
    let unitID: String
    var pointID: String?
}

extension QuestionBank {
    /// Every 考點 in syllabus order (subject, unit, point number).
    var allPoints: [StudyPoint] {
        Subjects.all.flatMap { subject in units(of: subject).flatMap { learning.points(of: $0.id) } }
    }
}

/// Loads 掌握度 for a question scope from the stored answers.
@MainActor
enum PointStatsLoader {
    /// Questions of the 今日 plan scope (特考 setting and 今日練習範圍), used by 今日 and 成績.
    static func dailyQuestions(bank: QuestionBank, includeSpecial: Bool) -> [Question] {
        ScopeStore.daily().filter(bank.reviewPool(includeSpecial: includeSpecial))
    }

    static func load(context: ModelContext, bank: QuestionBank, questions: [Question],
                     points: [StudyPoint]? = nil) -> [String: PointStat] {
        let store = StudyStore(context: context, scheduler: Scheduler(examDate: SettingsKey.examDateValue))
        let history = store.practiceHistory()
        let attempts = store.allAttempts().sorted(by: StudyReplay.attemptOrder).map {
            PointMastery.Attempt(questionID: $0.questionID, correct: $0.correct, unsure: $0.unsure, at: $0.timestamp)
        }
        return PointMastery.compute(points: points ?? bank.allPoints, scope: Set(questions.map(\.id)),
                                    questionsOfPoint: bank.learning.questionsOfPoint,
                                    attempts: attempts, open: history.open,
                                    ai: AIPractice.pointInput(facts: store.aiFacts(), bank: bank.ai))
    }

    /// Stats of the points that have at least one question in scope, in syllabus order.
    static func ordered(_ stats: [String: PointStat], bank: QuestionBank) -> [PointStat] {
        bank.allPoints.compactMap { stats[$0.id] }.filter { $0.questions > 0 }
    }
}

// MARK: - Pieces

/// 掌握度 label pill: 待加強, 還不穩, 穩定, 沒做過.
struct PointLabelChip: View {
    let label: PointLabel

    var body: some View {
        Text(label.title)
            .appFont(12, .bold, relativeTo: .caption1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .fixedSize()
    }

    private var fg: Color {
        switch label {
        case .needsWork: Palette.warn
        case .shaky: Palette.shaky
        case .steady: Palette.accent
        case .untouched: Palette.muted
        }
    }

    private var bg: Color {
        switch label {
        case .needsWork: Palette.warnSoft
        case .shaky: Palette.shakySoft
        case .steady: Palette.accentSoft
        case .untouched: Palette.hairline
        }
    }
}

/// Small numbered disc in front of a point name.
struct PointNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .appFont(12, .bold, relativeTo: .caption1)
            .monospacedDigit()
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(Palette.accentSoft))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// 考點 row of the unit page and the all-points list: 序號, name, 「歷屆 N 題 ・ 你：錯 x／做 y」, label.
struct PointRow: View {
    let stat: PointStat
    var divider = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 0) {
                if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        text
                        PointLabelChip(label: stat.label)
                        chevron
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) { text; chevron }
                        PointLabelChip(label: stat.label)
                    }
                }
                .padding(.vertical, 10)
                .frame(minHeight: 56)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("考點 \(stat.point.number)，\(stat.point.title)，\(stat.detailText)"
                            + (stat.ai.questions > 0 ? "，非官方 AI 題 \(stat.ai.questions) 題，\(stat.ai.countsText)" : "")
                            + "，\(stat.label.title)")
        .accessibilityHint("開啟重點講義")
        .accessibilityAddTraits(.isButton)
    }

    private var text: some View {
        HStack(alignment: .top, spacing: 10) {
            PointNumber(number: stat.point.number)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.point.title).appFont(15, .bold).multilineTextAlignment(.leading)
                Text(stat.detailText).appFont(12, relativeTo: .caption1).monospacedDigit()
                    .foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                if stat.ai.questions > 0 {
                    Text(stat.ai.answers == 0 ? "AI 題 \(stat.ai.questions) ・ 沒做過"
                                              : "AI 題 \(stat.ai.questions) ・ 你：\(stat.ai.countsText)")
                        .appFont(12, relativeTo: .caption1).monospacedDigit()
                        .foregroundStyle(Palette.noticeInk).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
    }
}

/// 最該補 row of 今日 and 成績: 科目 ・ 單元, point name, 錯 x／做 y (official only), label, and a separate 非官方 AI line.
struct WeakPointRow: View {
    let stat: PointStat
    /// One line from the nightly analysis (muted), e.g. 「3 次都把雙氧水當成免中和」.
    var reason: String? = nil
    var divider = true
    /// 「練 AI 題」 link, offered when the point has AI questions.
    var onPracticeAI: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.questionBank) private var bank

    private var context: String {
        let unit = bank.unitByID[stat.point.unitID]
        return [unit?.subject, unit?.name].compactMap { $0 }.joined(separator: " ・ ")
    }

    /// 「AI 題 8 ・ 你：錯 1／做 2」: AI answers stay apart from the official 「錯 x／做 y」 (noticeInk, as in `PointRow`).
    private var aiLine: some View {
        Text(stat.ai.answers == 0 ? "AI 題 \(stat.ai.questions) ・ 沒做過"
                                  : "AI 題 \(stat.ai.questions) ・ 你：\(stat.ai.countsText)")
            .appFont(12, relativeTo: .caption1).monospacedDigit()
            .foregroundStyle(Palette.noticeInk).multilineTextAlignment(.leading)
    }

    private var offersAIPractice: Bool { onPracticeAI != nil && stat.ai.questions > 0 }

    /// A point flagged by AI answers alone reads 「歷屆沒做過」 instead of 「錯 0／做 0」 next to its label.
    private var officialCounts: String { stat.answers == 0 ? "歷屆沒做過" : stat.countsText }

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
            rowButton
            if let onPracticeAI, offersAIPractice {
                // Its own line under the row, so the row's tap target (chevron included) and the link never overlap.
                HStack(alignment: .center, spacing: 8) {
                    aiLine
                    Spacer(minLength: 4)
                    Button {
                        Haptics.selection()
                        onPracticeAI()
                    } label: {
                        Text("練 AI 題 \(stat.ai.questions)").appFont(13, .bold, relativeTo: .footnote).monospacedDigit()
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(Palette.badge))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("練 \(stat.point.title) 的 \(stat.ai.questions) 題 AI 題")
                }
                .padding(.bottom, 2)
            }
        }
    }

    private var rowButton: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.leading)
                        Text(stat.point.title).appFont(15, .bold).multilineTextAlignment(.leading)
                        HStack(spacing: 8) {
                            Text(officialCounts).appFont(13, relativeTo: .footnote).monospacedDigit()
                                .foregroundStyle(Palette.muted)
                            PointLabelChip(label: stat.label)
                        }
                        if stat.ai.questions > 0, !offersAIPractice { aiLine }
                        if let reason, !reason.isEmpty {
                            // Every AI-written line carries a visible AI mark.
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Chip(text: "AI 分析", kind: .notice).fixedSize()
                                Text(reason).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.vertical, 10)
                .frame(minHeight: 56)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context)，\(stat.point.title)，\(officialCounts)，\(stat.label.title)"
                            + (reason.map { "，AI 分析：\($0)" } ?? ""))
        .accessibilityHint("開啟重點講義")
        .accessibilityAddTraits(.isButton)
    }
}

/// 「考點」 card of the unit page.
struct UnitPointsCard: View {
    let stats: [PointStat]
    let onOpen: (StudyPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("考點").appFont(15, .bold).padding(.top, 14).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(stats.enumerated()), id: \.element.id) { i, stat in
                PointRow(stat: stat, divider: i > 0) { onOpen(stat.point) }
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

/// 「重點講義」 row of the unit page.
struct HandoutLinkRow: View {
    let pointCount: Int
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text("重點講義").appFont(16, .bold)
                    Text("\(pointCount) 個考點 ・ AI 產生，請對照課本").appFont(12, relativeTo: .caption1)
                        .foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Four-colour stacked bar of 掌握度 with the numbers beside it (colour is never the only cue).
struct PointBar: View {
    let counts: [PointLabel: Int]
    /// Legend as filters (考點掌握度 page): the selected label, and the tap handler. Nil handler = plain legend.
    var selection: PointLabel? = nil
    var onSelect: ((PointLabel) -> Void)? = nil

    /// Bar order: 穩定, 還不穩, 待加強, 沒做過.
    static let order: [PointLabel] = [.steady, .shaky, .needsWork, .untouched]

    private func color(_ l: PointLabel) -> Color {
        switch l {
        case .steady: Palette.accent
        case .shaky: Palette.shaky
        case .needsWork: Palette.warn
        case .untouched: Palette.chipBorder
        }
    }

    var body: some View {
        let total = max(1, counts.values.reduce(0, +))
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Self.order, id: \.self) { l in
                        let n = counts[l] ?? 0
                        if n > 0 {
                            RoundedRectangle(cornerRadius: 3).fill(color(l))
                                .frame(width: max(4, (geo.size.width - 6) * CGFloat(n) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if let onSelect {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Self.order, id: \.self) { l in
                        let on = selection == l
                        Button {
                            Haptics.selection()
                            onSelect(l)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(l)).frame(width: 9, height: 9)
                                Text("\(l.title) \(counts[l] ?? 0)").appFont(13, on ? .bold : .regular, relativeTo: .footnote)
                                    .monospacedDigit()
                                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                            }
                            .foregroundStyle(on ? Palette.accent : Palette.ink)
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(Capsule().fill(on ? Palette.accentSoft : Color.clear))
                            .overlay(Capsule().strokeBorder(on ? Palette.accent : Palette.chipBorder, lineWidth: on ? 1.5 : 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(l.title) \(counts[l] ?? 0) 個")
                        .accessibilityHint(on ? "再點一次顯示全部" : "只看這一類")
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    }
                }
            } else {
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    ForEach(Self.order, id: \.self) { l in
                        HStack(spacing: 6) {
                            Circle().fill(color(l)).frame(width: 9, height: 9)
                            Text("\(l.title) \(counts[l] ?? 0)").appFont(13, relativeTo: .footnote).monospacedDigit()
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("考點掌握度：" + Self.order.map { "\($0.title) \(counts[$0] ?? 0) 個" }.joined(separator: "，"))
            }
        }
    }
}

// MARK: - 今日 card

/// 「最該補的考點」 under the progress card of 今日 (hidden by the caller when empty).
struct TodayWeakPointsCard: View {
    let stats: [PointStat]
    /// Point id → reason line; empty when the order comes from the rules alone.
    var reasons: [String: String] = [:]
    let onOpen: (PointStat) -> Void
    var onPracticeAI: ((PointStat) -> Void)? = nil
    let onAll: () -> Void
    private var analysis: ManualAnalysisStore { ManualAnalysisStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("最該補的考點").appFont(15, .bold).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                analyzeControl
                Button {
                    Haptics.selection()
                    onAll()
                } label: {
                    HStack(spacing: 3) {
                        Text("全部").appFont(14, .medium, relativeTo: .subheadline)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全部考點")
            }
            .padding(.top, 4)
            if let failure = analysis.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            ForEach(Array(stats.enumerated()), id: \.element.id) { i, stat in
                WeakPointRow(stat: stat, reason: reasons[stat.point.id], divider: i > 0,
                             onPracticeAI: onPracticeAI.map { cb in { cb(stat) } }) { onOpen(stat) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

extension TodayWeakPointsCard {
    /// 「現在分析」 at the top right: a button when allowed, otherwise a muted line saying why not.
    @ViewBuilder
    fileprivate var analyzeControl: some View {
        if let label = analysis.label {
            if label.enabled {
                Button {
                    Haptics.selection()
                    let ids = stats.map(\.point.id)
                    Task { await ManualAnalysisStore.shared.run(points: ids) }
                } label: {
                    Text(label.title).appFont(13, .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .background(Capsule().strokeBorder(Palette.accent, lineWidth: 1.5))
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("請 AI 依你的作答立刻分析，約需一分鐘")
            } else {
                HStack(spacing: 6) {
                    if analysis.running { ProgressView().controlSize(.small) }
                    Text(label.title).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

// MARK: - 成績 card

/// 「考點掌握度」 card of 成績: stacked bar, top five 最該補, 「看全部考點」.
struct StatsPointsCard: View {
    let stats: [PointStat]
    let onOpen: (PointStat) -> Void
    let onAll: () -> Void

    var body: some View {
        let weakest = PointMastery.weakest(stats, limit: PointMastery.statsLimit)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("考點掌握度").appFont(15, .bold).accessibilityAddTraits(.isHeader)
                Text("共 \(stats.count) 個考點").appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
            }
            PointBar(counts: PointMastery.counts(stats))
            if !weakest.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("最該補的考點").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .padding(.bottom, 4)
                    ForEach(Array(weakest.enumerated()), id: \.element.id) { i, stat in
                        WeakPointRow(stat: stat, divider: i > 0) { onOpen(stat) }
                    }
                }
            }
            Button {
                Haptics.selection()
                onAll()
            } label: {
                Text("看全部考點")
            }
            .buttonStyle(SecondaryButtonStyle(height: 48))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }
}

// MARK: - All points

/// 考點掌握度: the points the learner has answered, weakest first. The legend counts filter by label;
/// points never done collapse into one row that leads to the 單元 tab.
struct AllPointsView: View {
    var backLabel = "返回成績"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(ScopeStore.dailyKey) private var dailyScopeRaw = ""
    @State private var stats: [String: PointStat] = [:]
    @State private var handout: HandoutRoute?
    @State private var filter: PointLabel?

    var body: some View {
        let ordered = PointStatsLoader.ordered(stats, bank: bank)
        let counts = PointMastery.counts(ordered)
        let rows = PointMastery.answeredByWeakness(ordered).filter { filter == nil || $0.label == filter }
        let snapshot = InsightsStore.shared.snapshot
        let reasons: [String: String] = (snapshot?.isFresh() ?? false) ? (snapshot?.notes ?? [:]).compactMapValues { $0.reason.isEmpty ? nil : $0.reason } : [:]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("考點掌握度").headingFont(25)
                PointBar(counts: counts, selection: filter) { label in
                    withAnimation(.easeInOut(duration: 0.15)) { filter = filter == label ? nil : label }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
                if filter != .untouched {
                    listCard(rows, reasons: reasons, answered: ordered.contains { $0.label != .untouched })
                }
                if let untouched = counts[.untouched], untouched > 0, filter == nil || filter == .untouched {
                    untouchedRow(untouched)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: backLabel) { dismiss() }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("points")
        .onAppear(perform: load)
        .onChange(of: includeSpecial) { load() }
        .onChange(of: dailyScopeRaw) { load() }
        .navigationDestination(item: $handout) { HandoutView(route: $0, backLabel: "返回考點掌握度") }
    }

    private func load() {
        let qs = PointStatsLoader.dailyQuestions(bank: bank, includeSpecial: includeSpecial)
        stats = PointStatsLoader.load(context: context, bank: bank, questions: qs)
    }

    @ViewBuilder
    private func listCard(_ rows: [PointStat], reasons: [String: String], answered: Bool) -> some View {
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(answered ? "沒有「\(filter?.title ?? "")」的考點" : "還沒有做過的考點").appFont(15, .bold)
                if answered {
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) { filter = nil }
                    } label: {
                        Text("清除篩選").appFont(14, .medium, relativeTo: .subheadline).foregroundStyle(Palette.accent)
                            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("練習幾題後，這裡會依弱點排好，最弱的在最上面。")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, stat in
                    WeakPointRow(stat: stat, reason: reasons[stat.point.id], divider: i > 0) {
                        handout = HandoutRoute(unitID: stat.point.unitID, pointID: stat.point.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
    }

    private func untouchedRow(_ count: Int) -> some View {
        Button {
            Haptics.selection()
            dismiss()
            router.openUnitOverview()
        } label: {
            HStack(spacing: 10) {
                Text("還有 \(count) 個考點沒做過，到單元頁練").appFont(15, .medium)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}
