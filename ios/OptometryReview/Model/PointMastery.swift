import Foundation

/// 掌握度 label of a 考點. Counts only, never percentages; 「熟練」 stays a word for single questions.
enum PointLabel: Int, CaseIterable, Comparable {
    /// Weakest first, so sorting by raw value puts 待加強 before 還不穩.
    case needsWork, shaky, steady, untouched

    var title: String {
        switch self {
        case .needsWork: "待加強"
        case .shaky: "還不穩"
        case .steady: "穩定"
        case .untouched: "沒做過"
        }
    }

    static func < (a: PointLabel, b: PointLabel) -> Bool { a.rawValue < b.rawValue }
}

/// The learner's numbers for one 考點 inside a question scope.
struct PointStat: Equatable, Identifiable {
    let point: StudyPoint
    /// Questions of the scope tagged with this point (歷屆 N 題).
    let questions: Int
    /// 做: answers given on those questions (mock exams included).
    let answers: Int
    /// 錯: wrong answers, 看解答 included.
    let wrong: Int
    /// 未熟: tagged questions that are open mistakes now (the 錯題本 definition).
    let open: Int
    /// Distinct tagged questions answered at least once.
    let done: Int
    let label: PointLabel
    /// The learner's answers on this point's AI questions (非官方). They count at half weight in `label`;
    /// everything above stays official-only so 歷屆 numbers never include them.
    var ai = AIPointStat()

    var id: String { point.id }
    /// 「錯 3／做 4」 (official questions only)
    var countsText: String { "錯 \(wrong)／做 \(answers)" }
    /// 「歷屆 12 題 ・ 你：錯 3／做 4」
    var detailText: String { "歷屆 \(questions) 題 ・ 你：\(countsText)" }
}

/// AI-question counts of one 考點 (docs/AI出題與圖解.md 4.1: AI answers weigh 0.5 against 歷屆 1).
struct AIPointStat: Equatable {
    /// AI questions tagged with the point.
    var questions = 0
    var answers = 0
    var wrong = 0
    /// AI questions whose latest answer is wrong (the AI 錯題 definition).
    var open = 0
    /// Distinct AI questions answered at least once.
    var done = 0

    var countsText: String { "錯 \(wrong)／做 \(answers)" }
    var isEmpty: Bool { questions == 0 }
}

enum PointMastery {
    /// One answer, oldest first when passed to `compute`.
    struct Attempt: Equatable {
        let questionID: String
        let correct: Bool
        let unsure: Bool
        /// Answer time; only used to find the latest answer across official and AI answers (equal times keep list order).
        var at: Date = .distantPast
    }

    /// AI answers and the tags of AI questions, passed beside the official input of `compute`.
    struct AIInput {
        /// Oldest first.
        var attempts: [Attempt] = []
        var pointsOfQuestion: [String: [String]] = [:]
        var questionsOfPoint: [String: [String]] = [:]
        static let empty = AIInput()
    }

    /// Weight of one AI answer against one 歷屆 answer.
    static let aiWeight = 0.5

    /// 還不穩 below this many distinct answered questions.
    static let steadyMinQuestions = 3
    /// 待加強 needs at least this many answers for the wrong-ratio rule.
    static let weakMinAnswers = 3
    static let todayLimit = 3
    static let statsLimit = 5

    /// - Parameter lastCorrectButUnsure: the latest answer on the point was right but marked 猜的.
    static func label(answers: Int, wrong: Int, open: Int, done: Int, lastCorrectButUnsure: Bool) -> PointLabel {
        label(answers: Double(answers), wrong: Double(wrong), open: Double(open), done: Double(done),
              lastCorrectButUnsure: lastCorrectButUnsure)
    }

    /// Weighted form: AI answers enter as halves (see `aiWeight`).
    static func label(answers: Double, wrong: Double, open: Double, done: Double, lastCorrectButUnsure: Bool) -> PointLabel {
        if done == 0 { return .untouched }
        if open >= 2 || (answers >= Double(weakMinAnswers) && wrong * 2 >= answers) { return .needsWork }
        if open >= 1 || lastCorrectButUnsure || done < Double(steadyMinQuestions) { return .shaky }
        return .steady
    }

    /// Stats of every point that has questions in `scope`.
    /// - Parameters:
    ///   - scope: ids of the questions in play (pool, year range, 今日練習範圍).
    ///   - attempts: every answer, oldest first.
    ///   - open: ids of the open mistakes.
    static func compute(points: [StudyPoint], scope: Set<String>, questionsOfPoint: [String: [String]],
                        attempts: [Attempt], open: Set<String>, ai: AIInput = .empty) -> [String: PointStat] {
        var ids: [String: Set<String>] = [:]
        var pointsOfQuestion: [String: [String]] = [:]
        for p in points {
            let inScope = (questionsOfPoint[p.id] ?? []).filter(scope.contains)
            ids[p.id] = Set(inScope)
            for q in inScope { pointsOfQuestion[q, default: []].append(p.id) }
        }
        var answers: [String: Int] = [:], wrong: [String: Int] = [:], done: [String: Set<String>] = [:]
        var last: [String: Attempt] = [:]
        for a in attempts {
            for pid in pointsOfQuestion[a.questionID] ?? [] {
                answers[pid, default: 0] += 1
                if !a.correct { wrong[pid, default: 0] += 1 }
                done[pid, default: []].insert(a.questionID)
                last[pid] = a
            }
        }
        // AI answers: counted per point they are tagged with; the latest AI answer of a question decides 「未熟」.
        var aiAnswers: [String: Int] = [:], aiWrong: [String: Int] = [:], aiDone: [String: Set<String>] = [:]
        var aiLatest: [String: Attempt] = [:]
        var aiLast: [String: Attempt] = [:]
        for a in ai.attempts {
            aiLatest[a.questionID] = a
            for pid in ai.pointsOfQuestion[a.questionID] ?? [] {
                aiAnswers[pid, default: 0] += 1
                if !a.correct { aiWrong[pid, default: 0] += 1 }
                aiDone[pid, default: []].insert(a.questionID)
                aiLast[pid] = a
            }
        }
        var result: [String: PointStat] = [:]
        for p in points {
            let qs = ids[p.id] ?? []
            let openCount = qs.filter(open.contains).count
            let a = answers[p.id] ?? 0, w = wrong[p.id] ?? 0, d = done[p.id]?.count ?? 0
            let aiQs = ai.questionsOfPoint[p.id] ?? []
            let stat = AIPointStat(questions: aiQs.count, answers: aiAnswers[p.id] ?? 0, wrong: aiWrong[p.id] ?? 0,
                                   open: aiQs.filter { aiLatest[$0].map { !$0.correct } ?? false }.count,
                                   done: aiDone[p.id]?.count ?? 0)
            // The latest answer overall, official or AI.
            var newest = last[p.id]
            if let l = aiLast[p.id], newest == nil || l.at >= newest!.at { newest = l }
            let unsure = newest.map { $0.correct && $0.unsure } ?? false
            let w5 = aiWeight
            let weighted = label(answers: Double(a) + w5 * Double(stat.answers), wrong: Double(w) + w5 * Double(stat.wrong),
                                 open: Double(openCount) + w5 * Double(stat.open), done: Double(d) + w5 * Double(stat.done),
                                 lastCorrectButUnsure: unsure)
            result[p.id] = PointStat(point: p, questions: qs.count, answers: a, wrong: w, open: openCount, done: d,
                                     label: weighted, ai: stat)
        }
        return result
    }

    /// 最該補: 待加強 then 還不穩; ties by 未熟 desc, then 歷屆題數 desc, then point order.
    static func weakest(_ stats: [PointStat], limit: Int) -> [PointStat] {
        let candidates = stats.filter { $0.label == .needsWork || $0.label == .shaky }
        let sorted = candidates.sorted { a, b in
            if a.label != b.label { return a.label < b.label }
            if a.open != b.open { return a.open > b.open }
            if a.questions != b.questions { return a.questions > b.questions }
            return a.point.id.localizedStandardCompare(b.point.id) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }

    /// 考點掌握度 list: only points with at least one answer, 待加強 → 還不穩 → 穩定; inside a label the 最該補 order
    /// (未熟 desc, 歷屆題數 desc, point order).
    static func answeredByWeakness(_ stats: [PointStat]) -> [PointStat] {
        stats.filter { $0.label != .untouched }.sorted { a, b in
            if a.label != b.label { return a.label < b.label }
            if a.open != b.open { return a.open > b.open }
            if a.questions != b.questions { return a.questions > b.questions }
            return a.point.id.localizedStandardCompare(b.point.id) == .orderedAscending
        }
    }

    /// Points per label, for the stacked bar.
    static func counts(_ stats: [PointStat]) -> [PointLabel: Int] {
        Dictionary(grouping: stats, by: \.label).mapValues(\.count)
    }
}
