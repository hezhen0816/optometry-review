import SwiftUI
import SwiftData

/// Mistake-book filter, all set in the 篩選 sheet (科目, years, units, 錯因, 已熟練) and combined with AND.
struct MistakeFilter: Equatable {
    static let all = "全部"
    static let reasonOptions = [all] + MistakeReason.all

    var subject = all
    var reason = all
    /// Show mastered mistakes instead of the open ones.
    var mastered = false
    var years = YearSelection()
    /// Primary-unit ids of `subject`; empty = every unit.
    var units: Set<String> = []

    var reasonActive: Bool { reason != Self.all }
    private var activeUnits: Set<String> { subject == Self.all ? [] : units }

    /// `ignoreReason` is used by the ☆ view, which has no reason filter.
    func matches(subject s: String, reason r: String?, ignoreReason: Bool = false) -> Bool {
        guard subject == Self.all || s == subject else { return false }
        if ignoreReason { return true }
        if reasonActive && r != reason { return false }
        return true
    }

    func matches(_ q: Question, reason r: String?, saved: Bool, ignoringUnits: Bool = false) -> Bool {
        guard matches(subject: q.subject, reason: r, ignoreReason: saved), years.contains(q.year) else { return false }
        let units = ignoringUnits ? [] : activeUnits
        if !units.isEmpty {
            guard let u = q.primaryConcept, units.contains(u) else { return false }
        }
        return true
    }

    /// Units belong to one subject, so a new subject clears them.
    mutating func setSubject(_ s: String) {
        guard s != subject else { return }
        subject = s
        units = []
    }

    /// The sheet's 重設; the ☆ view (and 不用再練) has 科目, years and units only.
    func clearingSheet(saved: Bool) -> MistakeFilter {
        var f = self
        f.setSubject(Self.all)
        f.years = .all
        if !saved {
            f.reason = Self.all
            f.mastered = false
        }
        return f
    }

    /// Number of active conditions, shown as 「篩選・n」.
    func activeCount(saved: Bool) -> Int {
        (subject == Self.all ? 0 : 1) + (years.mode == .all ? 0 : 1) + activeUnits.count
            + (saved ? 0 : (reasonActive ? 1 : 0) + (mastered ? 1 : 0))
    }

    /// One removable tag per active condition, shown under the 篩選 button.
    struct Tag: Identifiable, Equatable {
        enum Kind: Hashable { case subject, years, unit(String), reason, mastered }
        let kind: Kind
        let label: String
        var id: Kind { kind }
    }

    /// `units` are the units of `subject` in display order (names for the unit tags).
    func tags(saved: Bool, units: [ConceptUnit]) -> [Tag] {
        var tags: [Tag] = []
        if subject != Self.all { tags.append(Tag(kind: .subject, label: subject)) }
        if let y = years.label { tags.append(Tag(kind: .years, label: y)) }
        for unit in units where activeUnits.contains(unit.id) {
            tags.append(Tag(kind: .unit(unit.id), label: unit.name))
        }
        if !saved {
            if reasonActive { tags.append(Tag(kind: .reason, label: reason)) }
            if mastered { tags.append(Tag(kind: .mastered, label: "已熟練")) }
        }
        return tags
    }

    /// Drops one condition; removing the subject also drops its units.
    mutating func remove(_ kind: Tag.Kind) {
        switch kind {
        case .subject: setSubject(Self.all)
        case .years: years = .all
        case .unit(let id): units.remove(id)
        case .reason: reason = Self.all
        case .mastered: mastered = false
        }
    }
}

/// 「篩選」 button (「篩選・n」 when active) followed by one removable tag per active condition.
struct MistakeFilterBar: View {
    let tags: [MistakeFilter.Tag]
    let onOpen: () -> Void
    let onRemove: (MistakeFilter.Tag.Kind) -> Void

    var body: some View {
        let active = !tags.isEmpty
        // Tags follow the button on its line and wrap below it.
        FlowLayout(spacing: 6, lineSpacing: 0) {
            Button {
                Haptics.selection()
                onOpen()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .semibold))
                    Text(active ? "篩選・\(tags.count)" : "篩選")
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .appFont(14, .medium, relativeTo: .subheadline)
                .monospacedDigit()
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(active ? Palette.accent : Palette.ink)
                .background(RoundedRectangle(cornerRadius: 12).fill(active ? Palette.accentSoft : Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Palette.accent : Palette.chipBorder, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active ? "篩選，已套用 \(tags.count) 項" : "篩選")
                    ForEach(tags) { tag in
                        Button {
                            Haptics.selection()
                            withAnimation(.easeInOut(duration: 0.15)) { onRemove(tag.kind) }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag.label).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            }
                            .appFont(13, .medium, relativeTo: .footnote)
                            .foregroundStyle(Palette.accent)
                            .padding(.leading, 12)
                            .padding(.trailing, 9)
                            .frame(height: 30)
                            .background(Capsule().fill(Palette.accentSoft))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除篩選：\(tag.label)")
                        .transition(.opacity)
                    }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

/// Navigation value for the read-only question detail.
struct QuestionDetailRoute: Hashable {
    var entry: String = "unknown"
    let id: String
    /// The list it was opened from, in its shown order (filters applied), for 上一題／下一題.
    var ids: [String] = []
    /// VoiceOver label of the back button: where the detail returns to.
    var backLabel = "返回錯題本"
}

/// What the ☆ view lists.
enum SavedKind: String, CaseIterable {
    case all = "全部"
    case bookmarked = "收藏"
    case noted = "筆記"
    case ai = "AI 解析"
}

extension MistakeCategories.Category {
    var title: String {
        switch self {
        case .all: "全部錯題"
        case .recent: "最近答錯"
        case .frequent: "錯最多次"
        case .relapsed: "熟練後又忘"
        case .parked: "不用再練"
        }
    }
}

/// Mistake book tab: category rows on top; each opens its list. Search and the ☆ view stay in the header.
struct MistakesView: View {
    @State private var path = NavigationPath()
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack(path: $path) {
            MistakesScreen(category: nil, path: $path)
                .onChange(of: router.rootRequest(AppRouter.Tab.mistakes)) { path = NavigationPath() }
                .interactivePopEnabled()
                .navigationDestination(for: SessionRequest.self) { req in
                    ReviewSessionView(request: req, pushed: true, backLabel: "返回錯題本")
                }
                .navigationDestination(for: QuestionDetailRoute.self) { route in
                    QuestionDetailView(route: route)
                }
                .navigationDestination(for: SavedNoteRoute.self) { route in
                    SavedNoteView(noteID: route.noteID, backLabel: "返回錯題本")
                }
                .navigationDestination(for: MistakeCategories.Category.self) { category in
                    if category == .parked {
                        ParkedMistakesView()
                    } else {
                        MistakesScreen(category: category, path: $path)
                    }
                }
        }
    }
}

/// One mistake list (a category, or the root's search and ☆ view) with the 篩選 button and sheet;
/// the root without search or ☆ shows the category rows instead.
struct MistakesScreen: View {
    /// nil = the tab root.
    let category: MistakeCategories.Category?
    @Binding var path: NavigationPath

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @Query(sort: \QuestionRecord.dueDate) private var records: [QuestionRecord]
    @Query private var notes: [QuestionNote]
    @Query private var explanations: [AIExplanation]

    @State private var filter = MistakeFilter()
    @State private var categories: MistakeCategories.Result?
    @State private var searching = false
    @State private var query = ""
    @State private var savedOnly = false
    @State private var savedKind = SavedKind.all
    @State private var showFilter = false
    /// Pending 再次挑戰 today and latest-answer guesses, refreshed with the categories.
    @State private var retryToday: Set<String> = []
    @State private var guessed: Set<String> = []
    /// 「練這 N 題」: the listed questions as one 自選練習 session.
    @State private var practice: SessionRequest?
    @State private var mode = MistakesMode.official
    @State private var savedSegment = SavedSegment.official
    @State private var aiPractice: AIPracticeRequest?
    @State private var aiMistakes: [AIMistake] = []
    @FocusState private var searchFocused: Bool

    private struct Item: Identifiable {
        let id: String
        let question: Question
        /// Next review day (exam-date rules applied); nil when not scheduled or resting before the exam.
        let due: Date?
        /// Signed whole days until `due`; zero or less reads 「今天複習」.
        let days: Int?
        let isOpen: Bool
        let mastered: Bool
        let reason: String?
        let bookmarked: Bool
        let hasNote: Bool
        var hasAI = false
        /// Answered wrong earlier today and not yet redone (the 今日 card's 再次挑戰); labelled 「今天複習」.
        var retryToday = false
        /// Latest answer was correct but marked 猜的.
        var guessed = false
    }

    private var scheduler: Scheduler {
        Scheduler(examDate: examDate > 0 ? Date(timeIntervalSince1970: examDate) : nil)
    }

    private func inPool(_ q: Question) -> Bool { q.examKind == ExamKind.general || includeSpecial }

    private var noteByID: [String: QuestionNote] {
        Dictionary(notes.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The category's questions in the active pool; only the mastered ones when `onlyMastered` is set.
    private func items(in category: MistakeCategories.Category, onlyMastered: Bool) -> [Item] {
        let ids = Set(categories?[category].ids ?? [])
        let notes = noteByID
        let s = scheduler
        let now = Date.now
        let plan = PreExamReviewPlanner.plan(records: records, scheduler: s, now: now)
        var seen = Set<String>()
        return records.compactMap { r in
            guard ids.contains(r.questionID), seen.insert(r.questionID).inserted, r.schedule.isMistake, !r.parked,
                  !onlyMastered || r.isMastered(using: s, at: now),
                  let q = bank.byID[r.questionID], inPool(q) else { return nil }
            return item(r, question: q, note: notes[r.questionID], scheduler: s, plan: plan, now: now)
        }
    }

    /// Category size in the active pool (特考 off hides 特考 questions).
    private func count(_ category: MistakeCategories.Category) -> Int {
        (categories?[category].ids ?? []).filter { bank.byID[$0].map(inPool) ?? false }.count
    }

    /// Changes whenever an answer, park or unpark lands, so the categories are recomputed.
    private var recordsFingerprint: Int {
        var h = Hasher()
        for r in records {
            h.combine(r.questionID)
            h.combine(r.lastAnswered)
            h.combine(r.parked)
        }
        return h.finalize()
    }

    private func loadCategories() {
        let store = StudyStore(context: context, scheduler: scheduler)
        categories = store.mistakeCategories()
        (retryToday, guessed) = store.mistakeMarks()
        aiMistakes = AIPractice.mistakes(facts: store.aiFacts(), bank: bank.ai)
    }

    /// Where a question detail opened from this list returns to.
    private var backLabel: String {
        if let category { return "返回\(category.title)" }
        return "返回錯題本"
    }

    /// The root shows category rows until search or the ☆ view is on.
    private var showsCategories: Bool { category == nil && !searching && !savedOnly }

    /// `plan` is the pre-exam assignment for the whole population, computed once per list.
    private func item(_ r: QuestionRecord, question q: Question, note n: QuestionNote?, scheduler s: Scheduler,
                      plan: [String: ReviewDue], now: Date) -> Item {
        let status = s.status(r.schedule, at: now, reviewDue: plan[r.questionID])
        return Item(id: r.questionID, question: q, due: status.nextReviewDate, days: status.daysUntilNextReview,
                    isOpen: status.isOpenMistake, mastered: status.mastered, reason: r.lastReason,
                    bookmarked: n?.bookmarked ?? false, hasNote: n?.hasText ?? false,
                    retryToday: retryToday.contains(r.questionID), guessed: guessed.contains(r.questionID))
    }

    /// Bookmarked, noted or AI-explained questions: open mistakes first, then the others by last change.
    private var savedItems: [Item] {
        let notes = noteByID
        let aiDates = Dictionary(explanations.map { ($0.questionID, $0.savedAt) }, uniquingKeysWith: { a, b in max(a, b) })
        var changed: [String: Date] = aiDates
        for n in self.notes where !n.isEmpty { changed[n.questionID] = max(changed[n.questionID] ?? .distantPast, n.updatedAt) }
        let records = Dictionary(self.records.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
        let s = scheduler
        let now = Date.now
        let plan = PreExamReviewPlanner.plan(records: self.records, scheduler: s, now: now)
        let all: [Item] = changed.keys.compactMap { id in
            guard let q = bank.byID[id], inPool(q) else { return nil }
            let n = notes[id]
            var item: Item
            if let r = records[id], r.schedule.isMistake {
                item = self.item(r, question: q, note: n, scheduler: s, plan: plan, now: now)
            } else {
                item = Item(id: id, question: q, due: nil, days: nil, isOpen: false, mastered: false,
                            reason: nil, bookmarked: n?.bookmarked ?? false, hasNote: n?.hasText ?? false,
                            retryToday: retryToday.contains(id), guessed: guessed.contains(id))
            }
            item.hasAI = aiDates[id] != nil
            return item
        }
        let open = Self.sorted(all.filter(\.isOpen))
        let others = all.filter { !$0.isOpen }
            .sorted { (changed[$0.id] ?? .distantPast, $0.id) > (changed[$1.id] ?? .distantPast, $1.id) }
        return open + others
    }

    private func savedMatch(_ item: Item) -> Bool {
        switch savedKind {
        case .all: true
        case .bookmarked: item.bookmarked
        case .noted: item.hasNote
        case .ai: item.hasAI
        }
    }

    /// Review day first (overdue and today's retries count as today), then question id for a stable order.
    private static func sorted(_ items: [Item]) -> [Item] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ item: Item) -> Date { item.retryToday ? today : max(today, cal.startOfDay(for: item.due ?? .distantFuture)) }
        return items.sorted { a, b in
            let da = day(a), db = day(b)
            if da != db { return da < db }
            return a.id < b.id
        }
    }

    /// List before the filter: the ☆ view, or open (or mastered) mistakes.
    private func base(for f: MistakeFilter) -> [Item] {
        savedOnly ? savedItems.filter(savedMatch) : Self.sorted(items(in: category ?? .all, onlyMastered: f.mastered))
    }

    private func apply(_ f: MistakeFilter, to items: [Item], ignoringUnits: Bool = false) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            f.matches(item.question, reason: item.reason, saved: savedOnly, ignoringUnits: ignoringUnits)
                && (needle.isEmpty || item.question.stem.lowercased().contains(needle))
        }
    }

    private var filtered: [Item] { apply(filter, to: base(for: filter)) }

    /// Live counts for the filter sheet: total, per primary unit (units of the draft ignored)
    /// and per year (years of the draft ignored).
    private func evaluate(_ f: MistakeFilter) -> MistakesFilterSheet.Counts {
        let items = base(for: f)
        let total = apply(f, to: items).count
        let perUnit = Dictionary(grouping: apply(f, to: items, ignoringUnits: true).compactMap(\.question.primaryConcept),
                                 by: { $0 }).mapValues(\.count)
        var anyYear = f
        anyYear.years = .all
        let perYear = Dictionary(grouping: apply(anyYear, to: items).map(\.question.year), by: { $0 }).mapValues(\.count)
        return .init(total: total, units: perUnit, years: perYear)
    }

    var body: some View {
        // Computed once per update: every item derives an FSRS status.
        let aiShown = category == nil && !searching && !savedOnly && mode == .ai
        let items = (showsCategories || aiShown || (savedOnly && savedSegment != .official)) ? [] : filtered
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let category {
                    BackButton(label: "返回錯題本") { dismiss() }
                        .padding(.leading, 10)
                        .padding(.bottom, -8)
                    titleLine(category.title, count: items.count)
                        .padding(.horizontal, 20)
                } else {
                    header(count: showsCategories || aiShown || (savedOnly && savedSegment != .official) ? nil : items.count)
                    if !searching && !savedOnly { modePicker }
                    if savedOnly { savedSegmentPicker }
                }
                if aiShown {
                    AIMistakesList(mistakes: aiMistakes) { m in
                        aiPractice = AIPracticeRequest(ids: [m.question.id], reviewID: m.question.id, reviewChosen: m.chosen)
                    }
                } else if savedOnly && savedSegment == .aiQuestions {
                    AISavedQuestionsList { q in aiPractice = AIPracticeRequest(ids: [q.id]) }
                } else if savedOnly && savedSegment == .aiNotes {
                    AISavedNotesList { n in path.append(SavedNoteRoute(noteID: n.noteID)) }
                } else if showsCategories {
                    categoryRows.transition(.opacity)
                } else {
                    if searching { searchField.transition(.opacity) }
                    if savedOnly { savedKindChips.transition(.opacity) }
                    MistakeFilterBar(tags: filter.tags(saved: savedOnly, units: bank.units(of: filter.subject)),
                                     onOpen: { showFilter = true }, onRemove: { filter.remove($0) })
                    list(items)
                }
            }
            .padding(.top, category == nil ? 20 : 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsCategories && !items.isEmpty {
                practiceBar(items)
            } else if category == nil && !searching && !savedOnly && mode == .ai && !aiMistakes.isEmpty {
                aiPracticeBar
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen(category == nil ? "mistakes" : "mistakesList")
        .firstVisitTip(key: SettingsKey.tipAIMistakesShown,
                       eligible: category == nil && !searching && !savedOnly && !aiMistakes.isEmpty,
                       title: "AI 錯題分開放",
                       message: "答錯的 AI 題在「AI 錯題」，再答對一次就移出。它們不進每日複習，也不算進歷屆的錯題數。")
        .sheet(isPresented: $showFilter) {
            MistakesFilterSheet(initial: filter, saved: savedOnly, evaluate: evaluate) { f in
                withAnimation(.easeInOut(duration: 0.15)) { filter = f }
            }
        }
        .fullScreenCover(item: $practice, onDismiss: loadCategories) { req in
            ReviewSessionView(request: req)
        }
        .fullScreenCover(item: $aiPractice, onDismiss: loadCategories) { req in
            AIPracticeView(request: req)
        }
        .onAppear(perform: loadCategories)
        .onChange(of: recordsFingerprint) { loadCategories() }
        .onChange(of: examDate) { loadCategories() }
    }

    // MARK: AI modes

    /// 歷屆 ｜ AI 錯題 under the title.
    private var modePicker: some View {
        SegmentPicker(options: MistakesMode.allCases.map(\.rawValue),
                      selection: Binding(get: { mode.rawValue }, set: { mode = MistakesMode(rawValue: $0) ?? .official })) {
            $0 == MistakesMode.ai.rawValue ? "AI 錯題 \(aiMistakes.count)" : "歷屆 \(count(.all))"
        }
        .monospacedDigit()
        .padding(.horizontal, 20)
        .coachTarget()
    }

    /// 歷屆 ｜ AI 題 ｜ AI 筆記 in the ☆ view.
    private var savedSegmentPicker: some View {
        SegmentPicker(options: SavedSegment.allCases.map(\.rawValue),
                      selection: Binding(get: { savedSegment.rawValue }, set: { savedSegment = SavedSegment(rawValue: $0) ?? .official })) {
            SavedSegment(rawValue: $0)?.title ?? $0
        }
        .padding(.horizontal, 20)
    }

    private var aiPracticeBar: some View {
        Button("練這 \(aiMistakes.count) 題") {
            Haptics.selection()
            aiPractice = AIPracticeRequest(ids: aiMistakes.map(\.question.id))
        }
        .buttonStyle(PrimaryButtonStyle(height: 52))
        .monospacedDigit()
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .readableBarWidth()
        .background(Palette.ground.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }

    // MARK: Categories

    private var categoryRows: some View {
        VStack(spacing: 12) {
            categoryButton(.all, icon: "book.closed", tint: Palette.accent, fill: Palette.accentSoft, bold: true)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            VStack(spacing: 0) {
                categoryButton(.recent, icon: "clock", tint: Palette.accent, fill: Palette.badge)
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 46)
                categoryButton(.frequent, icon: "chart.bar", tint: Palette.accent, fill: Palette.badge)
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 46)
                categoryButton(.relapsed, icon: "arrow.counterclockwise", tint: Palette.warn, fill: Palette.warnSoft,
                               note: "熟練後又答錯的題，最需要再看一次。", countColor: Palette.warn)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            categoryButton(.parked, icon: "minus.circle", tint: Palette.muted, fill: Palette.badge, countColor: Palette.muted)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
        .padding(.horizontal, 20)
    }

    private func categoryButton(_ c: MistakeCategories.Category, icon: String, tint: Color, fill: Color,
                                bold: Bool = false, note: String? = nil, countColor: Color = Palette.ink) -> some View {
        let n = count(c)
        return Button {
            Haptics.selection()
            path.append(c)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(fill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).appFont(16, bold ? .bold : .regular)
                    if let note {
                        Text(note).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(n)").appFont(16, .bold).monospacedDigit().foregroundStyle(countColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 2)
            .padding(.vertical, note == nil ? 0 : 10)
            .frame(minHeight: note == nil ? 56 : 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.title) \(n) 題")
    }

    private func titleLine(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).headingFont(32)
            Text("\(count) 題")
                .appFont(14, relativeTo: .subheadline)
                .foregroundStyle(Palette.muted)
        }
    }

    // MARK: Sections

    private func header(count: Int?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(savedOnly ? "收藏" : "錯題本").headingFont(32)
                if let count {
                    Text("\(count) 題")
                        .appFont(14, relativeTo: .subheadline)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                headerButton(icon: "magnifyingglass", on: searching, label: searching ? "關閉搜尋" : "搜尋題目") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searching.toggle()
                        if !searching { query = "" }
                    }
                    searchFocused = searching
                }
                headerButton(icon: savedOnly ? "star.fill" : "star", on: savedOnly,
                             label: savedOnly ? "回到錯題分類" : "只看收藏、筆記與 AI 解析") {
                    withAnimation(.easeInOut(duration: 0.2)) { savedOnly.toggle() }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func headerButton(icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Palette.onAccent : Palette.ink)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accent : Palette.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("搜尋題目文字", text: $query)
                .appFont(16)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    /// ☆ view: 全部 ・ 收藏 ・ 筆記 ・ AI 解析.
    private var savedKindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SavedKind.allCases, id: \.self) { kind in
                    let on = kind == savedKind
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) { savedKind = kind }
                    } label: {
                        HStack(spacing: 5) {
                            if let icon = icon(kind) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                            Text(kind.rawValue)
                        }
                        .appFont(14, .medium, relativeTo: .subheadline)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .foregroundStyle(on ? Palette.accent : Palette.ink)
                        .background(Capsule().fill(on ? Palette.accentSoft : Color.clear))
                        .overlay(Capsule().strokeBorder(on ? Palette.accent : Palette.chipBorder, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func icon(_ kind: SavedKind) -> String? {
        switch kind {
        case .all: nil
        case .bookmarked: "star.fill"
        case .noted: "note.text"
        case .ai: "sparkles"
        }
    }

    @ViewBuilder
    private func list(_ items: [Item]) -> some View {
        if items.isEmpty {
            let filteredOut = isFilteredOut
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.muted)
                Text(filteredOut ? "這個篩選目前沒有題目" : emptyText)
                    .appFont(15)
                    .foregroundStyle(Palette.muted)
                if filteredOut {
                    Button("清除篩選") {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) { clearFilters() }
                    }
                    .appFont(15, .bold)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    // Opens the read-only detail, paging through this list as shown.
                    Button {
                        path.append(QuestionDetailRoute(entry: "mistakes", id: item.id, ids: items.map(\.id), backLabel: backLabel))
                    } label: {
                        card(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// 「練這 N 題」: practices exactly the listed questions (after filters and search) as 自選練習.
    private func practiceBar(_ items: [Item]) -> some View {
        Button("練這 \(items.count) 題") {
            Haptics.selection()
            searchFocused = false
            practice = SessionRequest(queue: items.map(\.id), doneBefore: 0, isDaily: false, isCustom: true)
        }
        .buttonStyle(PrimaryButtonStyle(height: 52))
        .monospacedDigit()
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .readableBarWidth()
        .background(Palette.ground.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }

    /// The list has items before the filters, but none after (search has its own text).
    private var isFilteredOut: Bool {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let sheetActive = filter.subject != MistakeFilter.all || filter.years.mode != .all || !filter.units.isEmpty
            || (!savedOnly && filter.reasonActive)
        return sheetActive && !base(for: filter).isEmpty
    }

    /// Clears every filter; the 已熟練 view stays.
    private func clearFilters() {
        var f = filter.clearingSheet(saved: savedOnly)
        f.mastered = filter.mastered
        filter = f
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "找不到含「\(query)」的題目" }
        if savedOnly {
            switch savedKind {
            case .all: return "答題後點右上角星號收藏，或寫下筆記"
            case .bookmarked: return "答題後點右上角星號收藏"
            case .noted: return "答題後可在題目下方寫筆記"
            case .ai: return "看過 AI 解析的題目會列在這裡"
            }
        }
        if filter.mastered { return "還沒有熟練的錯題" }
        if let category, category != .all { return "這個分類目前沒有題目" }
        return "答錯的題目會自動收進來"
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.question.subject)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if item.bookmarked {
                    Image(systemName: "star.fill").foregroundStyle(Palette.warn).accessibilityLabel("已收藏")
                }
                if item.hasNote {
                    Image(systemName: "note.text").accessibilityLabel("有筆記")
                }
                if savedOnly && item.hasAI {
                    Image(systemName: "sparkles").accessibilityLabel("有 AI 解析")
                }
                Spacer(minLength: 4)
                dueLabel(item).lineLimit(1).fixedSize()
            }
            .appFont(12, relativeTo: .caption1)
            .foregroundStyle(Palette.muted)
            Text(item.question.stem)
                .appFont(15)
                .lineSpacing(4)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            let reason = item.isOpen || item.mastered ? item.reason : nil
            HStack(spacing: 6) {
                Text(item.question.sourceLabel)
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.guessed {
                    Text("猜的").appFont(12, .medium, relativeTo: .caption1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(Palette.accent)
                        .background(Capsule().fill(Palette.accentSoft))
                }
                if let reason {
                    Text(reason).appFont(12, .medium, relativeTo: .caption1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(Palette.warn)
                        .background(Capsule().fill(Palette.warnSoft))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看這題")
    }

    /// 「今天複習」 (warn) for today's retries and due reviews, or 「下次複習：N 天後」 (accent; muted regular once mastered).
    @ViewBuilder
    private func dueLabel(_ item: Item) -> some View {
        if item.retryToday {
            Text("今天複習").bold().foregroundStyle(Palette.warn)
        } else if let days = item.days {
            if days <= 0 {
                Text("今天複習").bold().foregroundStyle(Palette.warn)
            } else {
                Text("下次複習：\(DateText.nextReview(days: days))")
                    .fontWeight(item.mastered ? .regular : .bold)
                    .foregroundStyle(item.mastered ? Palette.muted : Palette.accent)
            }
        }
    }
}

/// 篩選 sheet of the mistake book. The ☆ view (and 不用再練) shows 科目, years and units only.
struct MistakesFilterSheet: View {
    let initial: MistakeFilter
    let saved: Bool
    /// What is being filtered, under the title.
    var subtitle: String? = nil
    struct Counts {
        let total: Int
        let units: [String: Int]
        let years: [Int: Int]
    }

    let evaluate: (MistakeFilter) -> Counts
    let onApply: (MistakeFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank

    @State private var draft = MistakeFilter()
    @State private var accuracy: [String: UnitAccuracy.Rate] = [:]
    @State private var loaded = false

    private var subject: String? { draft.subject == MistakeFilter.all ? nil : draft.subject }

    /// Year with the most items; the newer year wins a tie.
    static func busiestYear(_ counts: [Int: Int]) -> Int? {
        counts.filter { $0.value > 0 }.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    var body: some View {
        let result = evaluate(draft)
        return ScopeSheet(title: "篩選", subtitle: subtitle ?? (saved ? "收藏、筆記與 AI 解析" : "錯題"),
                          onClose: { dismiss() }, trailing: {
            SheetResetButton { draft = draft.clearingSheet(saved: saved) }
        }) {
            ScopeField(title: "科目") {
                SubjectChoice(subject: Binding(get: { subject }, set: { draft.setSubject($0 ?? MistakeFilter.all) }))
            }
            ScopeField(title: "年份") {
                YearChoice(selection: $draft.years, years: bank.availableYears, counts: result.years,
                           singleDefault: Self.busiestYear(result.years))
            }
            UnitChoice(subject: subject, units: subject.map(bank.units(of:)) ?? [], selected: $draft.units,
                       counts: result.units, accuracy: accuracy, countTitle: saved ? "題數" : "錯題")
            if !saved {
                ScopeField(title: "錯因") {
                    ChoiceChips(options: MistakeFilter.reasonOptions, selected: draft.reason) { draft.reason = $0 }
                }
                Toggle(isOn: $draft.mastered) { Text("只看已熟練").appFont(15) }
                    .tint(Palette.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            }
        } footer: {
            ScopeCountLine(prefix: "符合", count: result.total)
            Button("套用") {
                Haptics.selection()
                onApply(draft)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
        }
        .trackScreen("mistakesFilter")
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

/// 不用再練: parked questions with 「移回複習」 (back in review tomorrow).
struct ParkedMistakesView: View {
    /// Set when shown in a sheet from a session (close button instead of back).
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @Query(filter: #Predicate<QuestionRecord> { $0.parked }) private var parked: [QuestionRecord]

    /// Same 篩選 sheet as the ☆ view: 科目, years and units.
    @State private var filter = MistakeFilter()
    @State private var showFilter = false
    @State private var toast = false
    @State private var detail: QuestionDetailRoute?

    private struct Row: Identifiable {
        let id: String
        let question: Question
        let parkedAt: Date?
    }

    private var allRows: [Row] {
        var seen = Set<String>()
        return parked.compactMap { r in
            guard seen.insert(r.questionID).inserted, let q = bank.byID[r.questionID],
                  q.examKind == ExamKind.general || includeSpecial else { return nil }
            return Row(id: r.questionID, question: q, parkedAt: r.parkedAt)
        }
        .sorted { ($0.parkedAt ?? .distantPast, $0.id) > ($1.parkedAt ?? .distantPast, $1.id) }
    }

    private func rows(_ f: MistakeFilter, from all: [Row], ignoringUnits: Bool = false) -> [Row] {
        all.filter { f.matches($0.question, reason: nil, saved: true, ignoringUnits: ignoringUnits) }
    }

    /// Live counts for the filter sheet, as in the mistake lists.
    private func evaluate(_ f: MistakeFilter) -> MistakesFilterSheet.Counts {
        let all = allRows
        var anyYear = f
        anyYear.years = .all
        return .init(total: rows(f, from: all).count,
                     units: Dictionary(grouping: rows(f, from: all, ignoringUnits: true).compactMap(\.question.primaryConcept),
                                       by: { $0 }).mapValues(\.count),
                     years: Dictionary(grouping: rows(anyYear, from: all).map(\.question.year), by: { $0 }).mapValues(\.count))
    }

    var body: some View {
        let rows = self.rows(filter, from: allRows)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let onClose {
                        HStack {
                            Spacer()
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
                        .padding(.trailing, 10)
                    } else {
                        BackButton(label: "返回錯題本") { dismiss() }
                            .padding(.leading, 10)
                    }
                }
                .padding(.bottom, -8)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("不用再練").headingFont(32)
                    Text("\(rows.count) 題").appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 20)
                MistakeFilterBar(tags: filter.tags(saved: true, units: bank.units(of: filter.subject)),
                                 onOpen: { showFilter = true }, onRemove: { filter.remove($0) })
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(Palette.muted)
                        Text(filter.activeCount(saved: true) == 0 ? "沒有移出複習的題目" : "這個篩選目前沒有題目").appFont(15).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { card($0, ids: rows.map(\.id)) }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .overlay(alignment: .bottom) {
            if toast {
                Toast(text: "已移回複習")
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("mistakesParked")
        .sheet(isPresented: $showFilter) {
            MistakesFilterSheet(initial: filter, saved: true, subtitle: "不用再練", evaluate: evaluate) { f in
                withAnimation(.easeInOut(duration: 0.15)) { filter = f }
            }
        }
        .navigationDestination(item: $detail) { route in
            QuestionDetailView(route: route)
        }
    }

    private func card(_ row: Row, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                detail = QuestionDetailRoute(entry: "mistakes", id: row.id, ids: ids, backLabel: "返回不用再練")
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(row.question.subject).fontWeight(.medium).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.question.sourceLabel).lineLimit(1)
                    }
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    Text(row.question.stem)
                        .appFont(15)
                        .lineSpacing(4)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看這題")
            HStack(spacing: 8) {
                Text(parkedText(row.parkedAt)).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    restore(row.id)
                } label: {
                    Label("移回複習", systemImage: "arrow.uturn.backward")
                        .appFont(14, .bold, relativeTo: .subheadline)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func parkedText(_ date: Date?) -> String {
        guard let date else { return "已移出" }
        if Calendar.current.isDateInToday(date) { return "今天移出" }
        return "\(DateText.monthDay.string(from: date)) 移出"
    }

    private func restore(_ id: String) {
        let store = StudyStore(context: context, scheduler: Scheduler(examDate: SettingsKey.examDateValue))
        guard withAnimation(.easeInOut(duration: 0.2), { store.unpark(questionID: id) }) else { return }
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.2)) { toast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.2)) { toast = false }
        }
    }
}
