import SwiftUI
import SwiftData

/// Navigation value of 單元頁.
struct UnitRoute: Hashable {
    let unitID: String
}

// MARK: - Shared year-filter pieces

/// 「年份」 button opening the per-screen year sheet.
struct YearFilterButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 15, weight: .semibold))
                Text("年份").appFont(14, .bold)
            }
            .foregroundStyle(active ? Palette.onAccent : Palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? Palette.accent : Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "年份，已套用範圍" : "年份")
    }
}

/// 「範圍：110–115 年 ✕」 under a title; tapping clears the range.
struct YearRangeChip: View {
    let label: String
    let onClear: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { onClear() }
        } label: {
            HStack(spacing: 8) {
                Text("範圍：\(label)")
                Image(systemName: "xmark").font(.system(size: 11, weight: .heavy))
            }
            .appFont(14, .bold, relativeTo: .subheadline)
            .foregroundStyle(Palette.accent)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(Palette.accentSoft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除年份範圍：\(label)")
    }
}

/// 年份 sheet for 單元總覽、單元頁 (one shared range) and 單科分析 (its own).
struct YearFilterSheet: View {
    let initial: YearSelection
    /// Questions inside a range, for the footer.
    let count: (YearSelection) -> Int
    /// One line under the picker about what the range changes on this screen.
    let note: String
    let onApply: (YearSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.questionBank) private var bank
    @State private var draft = YearSelection()
    @State private var loaded = false

    var body: some View {
        ScopeSheet(title: "年份", subtitle: "下次打開還會記得。單元總覽和單元頁共用這個範圍，單科分析另外設定。",
                   onClose: { dismiss() }, trailing: {
            SheetResetButton { draft = .all }
        }) {
            YearChoice(selection: $draft, years: bank.availableYears)
            Text(note)
                .appFont(13, relativeTo: .footnote)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            ScopeCountLine(prefix: "範圍內共", count: count(draft))
            Button("套用") {
                Haptics.selection()
                onApply(draft)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
        }
        .presentationDetents([.medium, .large])
        .trackScreen("yearFilter")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = initial.normalized(years: bank.availableYears)
        }
    }
}

/// Loads the learner's per-unit numbers for a question set.
@MainActor
private struct UnitData {
    let rows: [String: UnitProgress.Row]
    let history: CustomPractice.History
    let wrongCounts: [String: Int]
    /// AI answers (kept apart from the official numbers above).
    var aiFacts: [AIAttemptFact] = []

    static func load(context: ModelContext, questions: [Question]) -> UnitData {
        let store = StudyStore(context: context, scheduler: Scheduler(examDate: SettingsKey.examDateValue))
        let history = store.practiceHistory()
        let attempts = store.allAttempts()
        var wrong: [String: Int] = [:]
        for a in attempts where !a.correct { wrong[a.questionID, default: 0] += 1 }
        return UnitData(rows: UnitProgress.compute(questions: questions,
                                                   attempts: attempts.map { ($0.questionID, $0.correct) },
                                                   history: history),
                        history: history, wrongCounts: wrong, aiFacts: store.aiFacts())
    }
}


// MARK: - 單元總覽

/// 單元 tab root: subject → chapter → unit with 歷屆 counts, AI 題 counts and open mistakes.
struct UnitOverviewList: View {
    let years: YearSelection
    let onOpen: (ConceptUnit) -> Void
    /// 「練這科歷屆題」.
    let onPracticeSubject: (String) -> Void
    /// 「練這科 AI 題」: the subject's AI questions in practice order.
    let onPracticeAI: ([String]) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @State private var data: UnitData?
    @State private var openSubject: String?

    private var questions: [Question] {
        bank.reviewPool(includeSpecial: includeSpecial).filter { years.contains($0.year) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Subjects.all, id: \.self) { subject in
                subjectCard(subject)
            }
        }
        .onAppear(perform: load)
        .onChange(of: years) { load() }
        .onChange(of: includeSpecial) { load() }
    }

    private func load() {
        data = UnitData.load(context: context, questions: questions)
    }

    private func row(_ id: String) -> UnitProgress.Row { data?.rows[id] ?? UnitProgress.Row() }

    private func aiCount(_ unitID: String) -> Int { bank.ai.questions(unit: unitID).count }

    private func subjectCard(_ subject: String) -> some View {
        let units = bank.units(of: subject)
        let total = units.map { row($0.id) }.reduce(UnitProgress.Row(), +)
        let aiTotal = bank.ai.questions(subject: subject).count
        let open = openSubject == subject
        return VStack(spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.25)) { openSubject = open ? nil : subject }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject).appFont(15, .bold).multilineTextAlignment(.leading)
                        Text("歷屆 \(total.questions) ・ \(aiTotal == 0 ? "沒有 AI 題" : "AI 題 \(aiTotal)") ・ 錯題 \(total.open)")
                            .appFont(12, relativeTo: .caption1)
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { if subject == Subjects.all.first { Color.clear.coachTarget() } }
            .accessibilityValue(open ? "已展開" : "已收合")
            if open {
                VStack(spacing: 0) {
                    columnHeader
                    ForEach(UnitProgress.sections(units)) { section in
                        if let title = section.title {
                            sectionHeader(title, total: section.units.map { row($0.id).questions }.reduce(0, +),
                                          ai: section.units.map { aiCount($0.id) }.reduce(0, +))
                        }
                        ForEach(section.units) { unit in
                            unitRow(unit)
                        }
                    }
                    practiceButtons(subject, aiTotal: aiTotal)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Text("單元").frame(maxWidth: .infinity, alignment: .leading)
                Text("歷屆").frame(width: 40, alignment: .trailing)
                Text("AI 題").foregroundStyle(Palette.noticeInk).frame(width: 46, alignment: .trailing)
                Text("錯題").frame(width: 34, alignment: .trailing)
                Color.clear.frame(width: 14, height: 1)
            }
            .appFont(11, relativeTo: .caption2)
            .foregroundStyle(Palette.muted)
            .frame(height: 30)
            .accessibilityHidden(true)
        }
    }

    private func sectionHeader(_ title: String, total: Int, ai: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(total)").appFont(13, relativeTo: .footnote).monospacedDigit().foregroundStyle(Palette.muted)
                    .frame(width: 40, alignment: .trailing)
                Text(ai == 0 ? "—" : "\(ai)").appFont(13, relativeTo: .footnote).monospacedDigit()
                    .foregroundStyle(ai == 0 ? Palette.muted : Palette.noticeInk)
                    .frame(width: 46, alignment: .trailing)
                Color.clear.frame(width: 34 + 8 + 14, height: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title)，歷屆 \(total) 題，AI 題 \(ai) 題")
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func unitRow(_ unit: ConceptUnit) -> some View {
        let r = row(unit.id)
        let ai = aiCount(unit.id)
        return Button {
            Haptics.selection()
            onOpen(unit)
        } label: {
            VStack(spacing: 0) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Text(unit.name).appFont(14).lineSpacing(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(r.questions)").appFont(14, relativeTo: .subheadline)
                        .frame(width: 40, alignment: .trailing)
                    Text(ai == 0 ? "—" : "\(ai)").appFont(14, relativeTo: .subheadline)
                        .foregroundStyle(ai == 0 ? Palette.muted : Palette.noticeInk)
                        .frame(width: 46, alignment: .trailing)
                    Text("\(r.open)").appFont(14, relativeTo: .subheadline)
                        .foregroundStyle(r.open > 0 ? Palette.warn : Palette.muted)
                        .frame(width: 34, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 14)
                }
                .monospacedDigit()
                .padding(.vertical, 8)
                .frame(minHeight: 52)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(unit.name)，歷屆 \(r.questions) 題，AI 題 \(ai) 題，錯題 \(r.open) 題")
        .accessibilityAddTraits(.isButton)
    }

    private func practiceButtons(_ subject: String, aiTotal: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Button("練這科歷屆題") { Haptics.selection(); onPracticeSubject(subject) }
                    .appFont(14, .bold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
                    .buttonStyle(.plain)
                Button("練這科 AI 題") {
                    Haptics.selection()
                    let qs = AIPractice.ordered(bank.ai.questions(subject: subject), facts: data?.aiFacts ?? [])
                    onPracticeAI(qs.map(\.id))
                }
                .appFont(14, .bold, relativeTo: .subheadline)
                .foregroundStyle(Palette.noticeInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice))
                .buttonStyle(.plain)
                .disabled(aiTotal == 0)
                .opacity(aiTotal == 0 ? 0.45 : 1)
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - 單元頁

/// One unit: stats, 「練這 N 題」 (the filtered list), past sittings, and its questions (opening the read-only detail).
struct UnitDetailView: View {
    let unitID: String
    /// Title of the screen the back button returns to.
    var backTitle = "歷屆試題"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(YearFilterStore.key(.units)) private var yearsRaw = ""
    @State private var data: UnitData?
    @State private var filter = Filter.all
    @State private var showYears = false
    /// 「練這 N 題」: the filtered list as one 自選練習 session.
    @State private var practice: SessionRequest?
    /// Pushed by item, not by NavigationLink value: the unit page is also pushed by item (from 單科分析),
    /// where a value link would not push.
    @State private var detail: QuestionDetailRoute?
    /// 考點 numbers of this unit within the year range, and the pushed 講義頁.
    @State private var pointStats: [String: PointStat] = [:]
    @State private var handoutRoute: HandoutRoute?
    @State private var aiPractice: AIPracticeRequest?

    /// 全部 last, like every segmented control.
    enum Filter: String, CaseIterable { case wrong, unseen, all }

    /// The questions the list shows (and 「練這 N 題」 practices) under `filter`.
    static func shown(_ qs: [Question], filter: Filter, history: CustomPractice.History) -> [Question] {
        qs.filter { q in
            switch filter {
            case .all: true
            case .wrong: history.open.contains(q.id)
            case .unseen: !history.seen.contains(q.id)
            }
        }
    }

    private var unit: ConceptUnit? { bank.unitByID[unitID] }
    private var years: YearSelection { YearFilterStore.decode(yearsRaw) }

    private func questions(in years: YearSelection) -> [Question] {
        bank.reviewPool(includeSpecial: includeSpecial)
            .filter { $0.primaryConcept == unitID && years.contains($0.year) }
            .sorted { ($1.year, $1.code, $0.number) < ($0.year, $0.code, $1.number) }
    }

    var body: some View {
        let qs = questions(in: years)
        let stat = UnitHistory.table(for: bank).stat(unitID)
        let shown = Self.shown(qs, filter: filter, history: data?.history ?? CustomPractice.History())
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let unit {
                    header(unit)
                    statsCard(qs)
                    learningSection(unit)
                    historyCard(stat)
                    filterPicker(qs)
                    questionList(shown, unit: unit)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { practiceBar(shown) }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("unit")
        .fullScreenCover(item: $aiPractice, onDismiss: load) { AIPracticeView(request: $0) }
        .onAppear(perform: load)
        .onChange(of: yearsRaw) { load() }
        .onChange(of: includeSpecial) { load() }
        .sheet(isPresented: $showYears) {
            YearFilterSheet(initial: years, count: { questions(in: $0).count },
                            note: "題數、正確率、錯題只算範圍內的題目；「歷屆出題」一律算全部場次。") { sel in
                YearFilterStore.set(sel, for: .units)
            }
        }
        .navigationDestination(item: $practice) { req in
            ReviewSessionView(request: req, pushed: true, backLabel: "返回\(unit?.name ?? "單元")", listSource: "unit")
        }
        .onChange(of: practice) { _, req in if req == nil { load() } }
        .navigationDestination(item: $detail) { route in
            QuestionDetailView(route: route)
        }
        .navigationDestination(item: $handoutRoute) { route in
            HandoutView(route: route, backLabel: "返回\(unit?.name ?? "單元")")
        }
    }

    private func load() {
        let qs = questions(in: years)
        data = UnitData.load(context: context, questions: qs)
        let points = bank.learning.points(of: unitID)
        pointStats = points.isEmpty ? [:] : PointStatsLoader.load(context: context, bank: bank, questions: qs, points: points)
    }

    /// 「重點講義」 row and the 「考點」 card under the stats row.
    @ViewBuilder
    private func learningSection(_ unit: ConceptUnit) -> some View {
        let points = bank.learning.points(of: unitID)
        if bank.learning.handouts[unitID] != nil {
            HandoutLinkRow(pointCount: points.count) { handoutRoute = HandoutRoute(unitID: unitID) }
        }
        let rows = points.compactMap { pointStats[$0.id] }
        if !rows.isEmpty {
            UnitPointsCard(stats: rows) { handoutRoute = HandoutRoute(unitID: unitID, pointID: $0.id) }
        }
    }

    private var topBar: some View {
        HStack {
            BackButton(label: "返回\(backTitle)") { dismiss() }
            Spacer()
            YearFilterButton(active: years.mode != .all) { showYears = true }
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .readableBarWidth()
        .padding(.vertical, 4)
        .background(Palette.ground.ignoresSafeArea(edges: .top))
    }

    private func header(_ unit: ConceptUnit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([unit.subject, unit.group].compactMap { $0 }.joined(separator: " ・ "))
                .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
            Text(unit.name).headingFont(25)
                .fixedSize(horizontal: false, vertical: true)
            if let label = years.label {
                YearRangeChip(label: label) { YearFilterStore.set(.all, for: .units) }
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 2)
    }

    private func statsCard(_ qs: [Question]) -> some View {
        let r = data?.rows[unitID] ?? UnitProgress.Row()
        let aiQs = bank.ai.questions(unit: unitID)
        let ai = AIPractice.tally(for: aiQs, facts: data?.aiFacts ?? [])
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                stat("歷屆題數", "\(r.questions)", unit: nil, note: "已做 \(r.seen)")
                stat("正確率", r.isSmallSample ? r.accuracyText : (r.percent.map(String.init) ?? "—"),
                     unit: r.percent == nil || r.isSmallSample ? nil : "%", note: r.isSmallSample ? "答對/作答" : nil)
                stat("錯題", "\(r.open)", unit: nil, note: "還沒熟練", warn: r.open > 0)
            }
            if !aiQs.isEmpty {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Text("AI 題 \(ai.questions) 題 ・ 做過 \(ai.done) ・ 錯 \(ai.open)")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    /// 「練歷屆題 N」 (follows the 錯題｜沒做過｜全部 segment) and 「練 AI 題 N」.
    private func practiceBar(_ shown: [Question]) -> some View {
        let aiQs = bank.ai.questions(unit: unitID)
        return HStack(spacing: 8) {
            Button("練歷屆題 \(shown.count)") { start(shown) }
                .buttonStyle(PrimaryButtonStyle(height: 52))
                .disabled(shown.isEmpty)
            if !aiQs.isEmpty {
                Button {
                    Haptics.selection()
                    let ordered = AIPractice.ordered(aiQs, facts: data?.aiFacts ?? [])
                    aiPractice = AIPracticeRequest(ids: ordered.map(\.id))
                } label: { Text("練 AI 題 \(aiQs.count)") }
                    .buttonStyle(SecondaryButtonStyle(height: 52))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .readableBarWidth()
        .background(Palette.ground.opacity(0.96).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func stat(_ title: String, _ value: String, unit: String?, note: String?, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).appFont(22, .bold, relativeTo: .title2).monospacedDigit()
                    .foregroundStyle(warn ? Palette.warn : Palette.ink)
                if let unit { Text(unit).appFont(13).foregroundStyle(Palette.muted) }
            }
            if let note { Text(note).appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func historyCard(_ stat: UnitHistory.Stat) -> some View {
        let table = UnitHistory.table(for: bank)
        let peak = max(1, stat.maximum)
        let spoken = zip(table.sittings, stat.counts).map { "\($0.label) 年 \($1) 題" }.joined(separator: "、")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("歷屆出題").appFont(15, .bold)
                Spacer()
                Text(table.rangeText).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("每場平均").appFont(14, relativeTo: .subheadline)
                Text(stat.averageText).appFont(24, .bold, relativeTo: .title2)
                Text(stat.averageDetail).appFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Palette.muted)
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            if stat.showsFloor {
                Text("歷屆每場最少 \(stat.minimum) 題")
                    .appFont(13, .bold, relativeTo: .footnote)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.accentSoft))
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(zip(table.sittings, stat.counts).enumerated()), id: \.offset) { _, pair in
                    let (sitting, n) = pair
                    let low = n == stat.minimum
                    VStack(spacing: 3) {
                        Text("\(n)").appFont(11, low ? .bold : .regular, relativeTo: .caption2).monospacedDigit()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(low ? Palette.accent : Palette.chart.opacity(0.55))
                            .frame(height: max(n > 0 ? 3 : 1, CGFloat(n) / CGFloat(peak) * 56))
                        Text(sitting.label).appFont(10, relativeTo: .caption2).foregroundStyle(Palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("歷屆每場題數：\(spoken)")
            if let note = footnote(table) {
                Text(note)
                    .appFont(12, relativeTo: .caption1).lineSpacing(3).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func footnote(_ table: UnitHistory.Table) -> String? {
        guard let makeup = table.sittings.first(where: { $0.label.hasSuffix("補") }) else { return nil }
        return "\(makeup.label) 是 \(makeup.label.dropLast()) 年花東補辦那一場。"
    }

    private func filterPicker(_ qs: [Question]) -> some View {
        let r = data?.rows[unitID] ?? UnitProgress.Row()
        let labels: [Filter: String] = [.all: "全部 \(r.questions)", .wrong: "錯題 \(r.open)", .unseen: "沒做過 \(r.unseen)"]
        return SegmentPicker(options: Filter.allCases.map(\.rawValue),
                             selection: Binding(get: { filter.rawValue },
                                                set: { filter = Filter(rawValue: $0) ?? .all }),
                             height: 40) { labels[Filter(rawValue: $0) ?? .all] ?? $0 }
            .monospacedDigit()
    }

    @ViewBuilder
    private func questionList(_ shown: [Question], unit: ConceptUnit) -> some View {
        let history = data?.history ?? CustomPractice.History()
        if shown.isEmpty {
            Text(filter == .wrong ? "這個單元目前沒有錯題" : filter == .unseen ? "這個單元的題目都做過了" : "這個範圍沒有題目")
                .appFont(15).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, q in
                    Button {
                        detail = QuestionDetailRoute(entry: "unit", id: q.id, ids: shown.map(\.id), backLabel: "返回\(unit.name)")
                    } label: {
                        questionRow(q, history: history, divider: i > 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
    }

    private func questionRow(_ q: Question, history: CustomPractice.History, divider: Bool) -> some View {
        let tag: (text: String, color: Color, bold: Bool)
        if history.open.contains(q.id) {
            tag = ("錯 \(data?.wrongCounts[q.id] ?? 0) 次", Palette.warn, true)
        } else if history.seen.contains(q.id) {
            // Never wrong: 答對; wrong before but no longer an open mistake (熟練 or 移出複習): 做過.
            tag = ((data?.wrongCounts[q.id] ?? 0) == 0 ? "答對" : "做過", Palette.accent, true)
        } else {
            tag = ("沒做過", Palette.muted, false)
        }
        return VStack(spacing: 0) {
            if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(q.sourceLabel).frame(maxWidth: .infinity, alignment: .leading)
                        Text(tag.text).fontWeight(tag.bold ? .bold : .regular).foregroundStyle(tag.color)
                    }
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    Text(q.stem).appFont(14, relativeTo: .subheadline).lineSpacing(3).lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看這題")
    }

    /// Practices exactly the listed questions (year range and segment applied), like 錯題本's 「練這 N 題」.
    private func start(_ shown: [Question]) {
        guard !shown.isEmpty else { return }
        Haptics.selection()
        practice = SessionRequest(queue: shown.map(\.id), doneBefore: 0, isDaily: false, isCustom: true)
    }
}
