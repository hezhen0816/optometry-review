import Foundation

/// One syllabus unit (題庫/觀念標籤表.json), e.g. 視覺光學-1.4 「鏡片稜鏡與偏心」.
struct ConceptUnit: Identifiable, Hashable {
    let id: String
    let subject: String
    /// Short name: the official name without its trailing parenthetical.
    let name: String
    /// Syllabus chapter (「眼球生理學」), nil for subjects without chapters.
    var group: String? = nil

    /// 「鏡片光學與特性(光學矯正鏡片、隱形眼鏡)」 → 「鏡片光學與特性」.
    static func shortName(_ name: String) -> String {
        let trimmed = name.replacingOccurrences(of: #"\s*[（(][^（）()]*[)）]\s*$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? name : trimmed
    }

    private struct Table: Decodable {
        struct Unit: Decodable { let id: String; let name: String; let group: String? }
        let subjects: [String: [Unit]]
    }

    /// Units from the bundled table in subject order, or nil when the table is missing.
    static func loadTable(_ bundle: Bundle = .main) -> [ConceptUnit]? {
        guard let url = bundle.url(forResource: "觀念標籤表", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        return parse(table)
    }

    static func load(json data: Data) -> [ConceptUnit]? {
        (try? JSONDecoder().decode(Table.self, from: data)).map(parse)
    }

    private static func parse(_ table: Table) -> [ConceptUnit] {
        let order = Subjects.all + table.subjects.keys.filter { !Subjects.all.contains($0) }.sorted()
        return order.flatMap { subject in
            (table.subjects[subject] ?? []).map {
                ConceptUnit(id: $0.id, subject: subject, name: shortName($0.name), group: $0.group)
            }
        }
    }

    /// Fallback for in-memory banks: one unit per primary concept, named by id.
    static func derived(from questions: [Question]) -> [ConceptUnit] {
        var seen = Set<String>()
        var units: [ConceptUnit] = []
        for q in questions {
            guard let id = q.primaryConcept, seen.insert(id).inserted else { continue }
            units.append(ConceptUnit(id: id, subject: q.subject, name: id))
        }
        return units.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

/// Year part of a practice scope: every year, one year, or an inclusive range (ROC years).
struct YearSelection: Codable, Equatable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        case all, single, range

        /// Segment order: 全部 always last.
        static let segmentOrder: [Mode] = [.single, .range, .all]
        var label: String {
            switch self {
            case .all: "全部"
            case .single: "單一年"
            case .range: "範圍"
            }
        }
    }

    var mode: Mode = .all
    /// The year of `.single`, the lower bound of `.range`.
    var from: Int = 0
    var to: Int = 0

    static let all = YearSelection()

    func contains(_ year: Int) -> Bool {
        switch mode {
        case .all: true
        case .single: year == from
        case .range: (min(from, to)...max(from, to)).contains(year)
        }
    }

    /// 「115 年」, 「110–115 年」; nil for every year.
    var label: String? {
        switch mode {
        case .all: nil
        case .single: "\(from) 年"
        case .range: from == to ? "\(from) 年" : "\(from)–\(to) 年"
        }
    }

    /// Endpoints clamped into the available years and sorted; unset endpoints become the bounds.
    func normalized(years: [Int]) -> YearSelection {
        let lower = years.min() ?? 106, upper = years.max() ?? 115
        func clamp(_ y: Int, _ fallback: Int) -> Int { y == 0 ? fallback : min(upper, max(lower, y)) }
        var s = self
        switch mode {
        case .all:
            s.from = clamp(from, lower); s.to = clamp(to, upper)
        case .single:
            s.from = clamp(from, upper); s.to = s.from
        case .range:
            let a = clamp(from, lower), b = clamp(to, upper)
            s.from = min(a, b); s.to = max(a, b)
        }
        return s
    }
}

/// Which questions a practice draws from: one subject or all, years, and syllabus units (empty = every unit).
struct PracticeScope: Codable, Equatable, Hashable {
    /// nil = every subject.
    var subject: String?
    var years = YearSelection()
    /// Primary-unit ids of `subject`; empty = every unit. Ignored without a subject.
    var units: Set<String> = []

    static let all = PracticeScope()

    var isAll: Bool { subject == nil && years.mode == .all && units.isEmpty }
    var activeUnits: Set<String> { subject == nil ? [] : units }

    func contains(_ q: Question) -> Bool {
        if let subject, q.subject != subject { return false }
        guard years.contains(q.year) else { return false }
        let units = activeUnits
        if !units.isEmpty {
            guard let unit = q.primaryConcept, units.contains(unit) else { return false }
        }
        return true
    }

    func filter(_ questions: [Question]) -> [Question] { questions.filter(contains) }

    /// Units belong to one subject, so switching subjects clears them.
    mutating func setSubject(_ s: String?) {
        guard s != subject else { return }
        subject = s
        units = []
    }

    /// Selecting every unit is the same as selecting none.
    mutating func toggleUnit(_ id: String, among all: [String]) {
        if units.contains(id) { units.remove(id) } else { units.insert(id) }
        if !all.isEmpty, Set(all).isSubset(of: units) { units = [] }
    }

    /// 「全部題庫」, 「視覺光學 ・ 110–115 年」, 「視覺光學 ・ 鏡片稜鏡與偏心」, 「視覺光學 ・ 3 個單元」.
    func label(unitName: (String) -> String?) -> String {
        var parts: [String] = []
        if let subject { parts.append(subject) }
        if let y = years.label { parts.append(y) }
        let units = activeUnits
        if units.count == 1, let id = units.first {
            parts.append(unitName(id) ?? "1 個單元")
        } else if units.count > 1 {
            parts.append("\(units.count) 個單元")
        }
        return parts.isEmpty ? "全部題庫" : parts.joined(separator: " ・ ")
    }
}

/// 自選練習 choice: scope, which questions, and how many.
struct CustomPracticeChoice: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// Never answered.
        case unseen
        /// Open (not yet mastered) mistakes, most urgent first.
        case missed
        case all

        var label: String {
            switch self {
            case .unseen: "沒做過"
            case .missed: "未熟練錯題"
            case .all: "全部"
            }
        }
    }

    /// Size options, in order: 「<每天想做幾題> 題」 (`goalSize`), 「自訂」 (any positive size), 「全部」 (0).
    static let goalSize = -1
    /// 「自訂」 stepper: 5–200 in steps of 5, starting at 30.
    static let customRange = 5...200
    static let customStep = 5
    static let customDefault = 30

    var isCustomSize: Bool { size > 0 }

    /// Choices stored before the goal option existed (fixed 10／20 題): a size equal to the daily goal becomes
    /// the goal option; any other fixed size stays as a 「自訂」 size.
    func normalized(goal: Int) -> CustomPracticeChoice {
        var c = self
        if c.size == goal { c.size = Self.goalSize }
        return c
    }

    /// Stepper ceiling: the matches, rounded up to a step, within the custom range.
    static func customUpper(matched: Int) -> Int {
        let up = (max(matched, 1) + customStep - 1) / customStep * customStep
        return min(customRange.upperBound, max(customRange.lowerBound, up))
    }

    var scope = PracticeScope()
    var kind: Kind = .unseen
    var size = CustomPracticeChoice.goalSize

    /// Questions this round takes from `matched` matches.
    func take(_ matched: Int, goal: Int = SettingsKey.defaultDailyGoal) -> Int {
        if size == 0 { return matched }
        return min(size < 0 ? max(1, goal) : size, matched)
    }
}

/// Pure question selection for 自選練習.
enum CustomPractice {
    /// What the learner has done, by question id.
    struct History: Equatable {
        var seen: Set<String> = []
        /// Open (unmastered) mistakes, most urgent first.
        var openOrder: [String] = [] { didSet { open = Set(openOrder) } }
        private(set) var open: Set<String> = []

        init(seen: Set<String> = [], openOrder: [String] = []) {
            self.seen = seen
            self.openOrder = openOrder
            open = Set(openOrder)
        }
    }

    /// Questions matching kind and scope (ignoring units when `ignoringUnits`), unordered.
    static func matches(pool: [Question], choice: CustomPracticeChoice, history: History,
                        ignoringUnits: Bool = false) -> [Question] {
        var scope = choice.scope
        if ignoringUnits { scope.units = [] }
        return pool.filter { q in
            guard scope.contains(q) else { return false }
            switch choice.kind {
            case .unseen: return !history.seen.contains(q.id)
            case .missed: return history.open.contains(q.id)
            case .all: return true
            }
        }
    }

    /// Match count per primary unit, for the unit list (units of the choice are not applied).
    static func unitCounts(pool: [Question], choice: CustomPracticeChoice, history: History) -> [String: Int] {
        var counts: [String: Int] = [:]
        for q in matches(pool: pool, choice: choice, history: history, ignoringUnits: true) {
            if let u = q.primaryConcept { counts[u, default: 0] += 1 }
        }
        return counts
    }

    /// The session queue: 未熟練錯題 by urgency, the other kinds shuffled; trimmed to the chosen size.
    static func queue<G: RandomNumberGenerator>(pool: [Question], choice: CustomPracticeChoice, history: History,
                                                goal: Int = SettingsKey.defaultDailyGoal,
                                                using rng: inout G) -> [String] {
        let ids = matches(pool: pool, choice: choice, history: history).map(\.id)
        var ordered: [String]
        if choice.kind == .missed {
            let set = Set(ids)
            ordered = history.openOrder.filter { set.contains($0) }
        } else {
            ordered = ids.shuffled(using: &rng)
        }
        return Array(ordered.prefix(choice.take(ids.count, goal: goal)))
    }
}

/// Per-unit accuracy from every recorded attempt.
enum UnitAccuracy {
    struct Rate: Equatable {
        var correct = 0
        var total = 0
        var percent: Int? { SubjectAnalysis.percent(correct: correct, total: total) }
    }

    static func compute(attempts: [(questionID: String, correct: Bool)], bank: QuestionBank) -> [String: Rate] {
        var rates: [String: Rate] = [:]
        for a in attempts {
            guard let unit = bank.byID[a.questionID]?.primaryConcept else { continue }
            rates[unit, default: Rate()].total += 1
            if a.correct { rates[unit]!.correct += 1 }
        }
        return rates
    }
}

/// Stored scopes: the 今日 new-question scope and the last 自選練習 choice (JSON strings in UserDefaults).
enum ScopeStore {
    static let dailyKey = "scope.daily"
    static let customKey = "scope.custom"

    static func daily(_ defaults: UserDefaults = .standard) -> PracticeScope {
        decode(defaults.string(forKey: dailyKey)) ?? .all
    }

    static func setDaily(_ scope: PracticeScope, defaults: UserDefaults = .standard) {
        defaults.set(encode(scope), forKey: dailyKey)
    }

    static func custom(_ defaults: UserDefaults = .standard) -> CustomPracticeChoice {
        decode(defaults.string(forKey: customKey)) ?? CustomPracticeChoice()
    }

    static func setCustom(_ choice: CustomPracticeChoice, defaults: UserDefaults = .standard) {
        defaults.set(encode(choice), forKey: customKey)
    }

    /// One-time move of the retired 設定「年份」 range into the daily scope; the old keys are removed.
    static func migrateLegacyYears(defaults: UserDefaults = .standard, availableYears: [Int]) {
        let from = defaults.object(forKey: SettingsKey.yearFrom) as? Int
        let to = defaults.object(forKey: SettingsKey.yearTo) as? Int
        guard from != nil || to != nil else { return }
        defaults.removeObject(forKey: SettingsKey.yearFrom)
        defaults.removeObject(forKey: SettingsKey.yearTo)
        guard defaults.string(forKey: dailyKey) == nil else { return }
        let lower = availableYears.min() ?? 106, upper = availableYears.max() ?? 115
        var years = YearSelection(mode: .range, from: from ?? lower, to: to ?? upper).normalized(years: availableYears)
        if years.from == lower && years.to == upper {
            years = .all
        } else if years.from == years.to {
            years.mode = .single
        }
        var scope = PracticeScope.all
        scope.years = years
        setDaily(scope, defaults: defaults)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func decode<T: Decodable>(_ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
