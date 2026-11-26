import Foundation

/// How many questions each syllabus unit had in every regular (一般) sitting, by primary unit.
/// Always every regular sitting: the year filter and the 特考 setting never change these figures.
enum UnitHistory {
    struct Sitting: Equatable {
        let code: String
        /// 「106」, 「106補」 (花東考區補辦).
        let label: String
    }

    struct Stat: Equatable {
        /// Questions per sitting, in `Table.sittings` order.
        let counts: [Int]

        var total: Int { counts.reduce(0, +) }
        var minimum: Int { counts.min() ?? 0 }
        var maximum: Int { counts.max() ?? 0 }
        var average: Double { counts.isEmpty ? 0 : Double(total) / Double(counts.count) }
        /// One decimal, without a trailing 「.0」: 「13.3」, 「5」.
        var averageText: String {
            let tenths = Int((average * 10).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        }
        /// 「歷屆每場最少 N 題」 is only worth saying from three questions up.
        var showsFloor: Bool { minimum >= UnitHistory.floorThreshold }
        /// Text after the average on the unit page; the minimum is left to the 「歷屆每場最少 N 題」 chip when it shows.
        var averageDetail: String {
            showsFloor ? "題 ・ 最多 \(maximum)" : "題 ・ 最少 \(minimum)、最多 \(maximum)"
        }
        /// 「歷屆每場 13.3 題（7–20）」
        var summary: String { "歷屆每場 \(averageText) 題（\(minimum)–\(maximum)）" }
    }

    struct Table: Equatable {
        let sittings: [Sitting]
        let stats: [String: Stat]

        func stat(_ unitID: String) -> Stat {
            stats[unitID] ?? Stat(counts: Array(repeating: 0, count: sittings.count))
        }

        /// 「106–115 年一般考試 11 場」
        var rangeText: String {
            let years = sittings.compactMap { Int($0.label.prefix(3)) }
            guard let first = years.min(), let last = years.max() else { return "一般考試" }
            return "\(first)–\(last) 年一般考試 \(sittings.count) 場"
        }
    }

    static let floorThreshold = 3

    /// Regular sittings, oldest first; a same-year makeup sitting follows its regular one.
    static func sittings(_ papers: [Paper]) -> [Sitting] {
        let general = papers.filter { $0.examKind == ExamKind.general }
        let byCode = Dictionary(grouping: general, by: \.code)
        let ordered = byCode.keys.sorted { a, b in
            let pa = byCode[a]!.first!, pb = byCode[b]!.first!
            let na = pa.sessionNote?.isEmpty == false, nb = pb.sessionNote?.isEmpty == false
            return (pa.year, na ? 1 : 0, a) < (pb.year, nb ? 1 : 0, b)
        }
        return ordered.map { code in
            let p = byCode[code]!.first!
            let noted = p.sessionNote?.isEmpty == false
            return Sitting(code: code, label: noted ? "\(p.year)補" : "\(p.year)")
        }
    }

    static func compute(bank: QuestionBank) -> Table {
        let sittings = sittings(bank.papers)
        let index = Dictionary(uniqueKeysWithValues: sittings.enumerated().map { ($1.code, $0) })
        var counts: [String: [Int]] = [:]
        for q in bank.questions where q.examKind == ExamKind.general {
            guard let unit = q.primaryConcept, let i = index[q.code] else { continue }
            counts[unit, default: Array(repeating: 0, count: sittings.count)][i] += 1
        }
        return Table(sittings: sittings, stats: counts.mapValues(Stat.init(counts:)))
    }

    @MainActor private static var cache: [ObjectIdentifier: Table] = [:]

    /// The bank is immutable, so one table per bank instance is enough.
    @MainActor
    static func table(for bank: QuestionBank) -> Table {
        let key = ObjectIdentifier(bank)
        if let t = cache[key] { return t }
        let t = compute(bank: bank)
        cache[key] = t
        return t
    }
}

/// The learner's numbers per unit inside one question set (active pool and year range).
enum UnitProgress {
    struct Row: Equatable {
        var questions = 0
        var seen = 0
        /// Attempts on these questions, every answer counted (重做同一題也算).
        var correct = 0
        var answers = 0
        /// Open mistakes: the 錯題本／自選練習「未熟練錯題」 set.
        var open = 0

        var percent: Int? { SubjectAnalysis.percent(correct: correct, total: answers) }
        /// Fewer answers than this show 「答對/作答」 counts instead of a percentage.
        static let minAnswersForPercent = 5
        var isSmallSample: Bool { answers > 0 && answers < Self.minAnswersForPercent }
        /// 「—」 (no answers), 「1/2」 (small sample) or 「63%」.
        var accuracyText: String {
            if answers == 0 { return "—" }
            if isSmallSample { return "\(correct)/\(answers)" }
            return percent.map { "\($0)%" } ?? "—"
        }
        /// Spoken form for VoiceOver.
        var accuracySpoken: String {
            if answers == 0 { return "還沒有作答" }
            if isSmallSample { return "作答 \(answers) 次答對 \(correct) 次" }
            return percent.map { "\($0)%" } ?? "還沒有作答"
        }
        /// Below 50% from a big enough sample: shown in warn color.
        var isWeak: Bool { !isSmallSample && (percent ?? 100) < 50 }
        var unseen: Int { questions - seen }

        static func + (a: Row, b: Row) -> Row {
            Row(questions: a.questions + b.questions, seen: a.seen + b.seen, correct: a.correct + b.correct,
                answers: a.answers + b.answers, open: a.open + b.open)
        }
    }

    /// - Parameters:
    ///   - questions: the questions to count (pool already narrowed by years).
    ///   - attempts: every recorded answer.
    ///   - history: seen questions and open mistakes (`StudyStore.practiceHistory`).
    static func compute(questions: [Question], attempts: [(questionID: String, correct: Bool)],
                        history: CustomPractice.History) -> [String: Row] {
        var unitOf: [String: String] = [:]
        var rows: [String: Row] = [:]
        for q in questions {
            guard let unit = q.primaryConcept else { continue }
            unitOf[q.id] = unit
            rows[unit, default: Row()].questions += 1
            if history.seen.contains(q.id) { rows[unit]!.seen += 1 }
            if history.open.contains(q.id) { rows[unit]!.open += 1 }
        }
        for a in attempts {
            guard let unit = unitOf[a.questionID] else { continue }
            rows[unit]!.answers += 1
            if a.correct { rows[unit]!.correct += 1 }
        }
        return rows
    }

    /// Consecutive units sharing a chapter; units without a chapter form untitled sections.
    struct Section: Identifiable {
        let id: String
        let title: String?
        let units: [ConceptUnit]
    }

    static func sections(_ units: [ConceptUnit]) -> [Section] {
        var result: [Section] = []
        for u in units {
            if let last = result.last, let g = u.group, last.title == g {
                result[result.count - 1] = Section(id: last.id, title: g, units: last.units + [u])
            } else {
                result.append(Section(id: u.id, title: u.group, units: [u]))
            }
        }
        return result
    }
}

/// Year range remembered across launches: 單元總覽 and 單元頁 share `units`; 單科分析 keeps its own.
enum YearFilterStore {
    enum Screen: String, CaseIterable {
        case units, subjectDetail
    }

    /// Pre-sharing keys (one per unit screen), folded into `units` by `migrateLegacy`.
    static let legacyKeys = ["yearFilter.unitOverview", "yearFilter.unitDetail"]

    /// Existing users start from the overview's range; the old per-screen keys are removed.
    static func migrateLegacy(defaults: UserDefaults = .standard) {
        if defaults.string(forKey: key(.units)) == nil, let old = defaults.string(forKey: legacyKeys[0]) {
            defaults.set(old, forKey: key(.units))
        }
        legacyKeys.forEach(defaults.removeObject(forKey:))
    }

    static func key(_ screen: Screen) -> String { "yearFilter.\(screen.rawValue)" }

    static func get(_ screen: Screen, defaults: UserDefaults = .standard) -> YearSelection {
        ScopeStore.decode(defaults.string(forKey: key(screen))) ?? .all
    }

    static func set(_ selection: YearSelection, for screen: Screen, defaults: UserDefaults = .standard) {
        if selection.mode == .all {
            defaults.removeObject(forKey: key(screen))
        } else {
            defaults.set(ScopeStore.encode(selection), forKey: key(screen))
        }
    }

    /// Decodes the raw `@AppStorage` string of a screen.
    static func decode(_ raw: String) -> YearSelection {
        ScopeStore.decode(raw) ?? .all
    }
}
