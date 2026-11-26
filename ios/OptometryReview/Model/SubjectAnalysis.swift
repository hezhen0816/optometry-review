import Foundation
import SwiftData

/// Aggregations for 單科分析. Pure functions over plain facts; `StudyStore.subjectReport` gathers the facts.
enum SubjectAnalysis {
    /// Exam pace of the national exam: 60 minutes for 50 questions.
    static let examPaceSeconds = 72
    static let yearRange = 106...115
    /// A question counts as 常錯 after this many wrong answers.
    static let frequentWrongThreshold = 2
    static let frequentWrongLimit = 5
    /// A unit can be 弱 only after this many answers (counted mock exams included).
    static let weakUnitMinAttempts = 5
    /// A year can be 最弱 only after this many answers.
    static let yearMinAttempts = 5
    static let weakUnitLimit = 3
    /// Units with fewer questions in the whole bank are flagged 題目少.
    static let fewQuestionsThreshold = 10

    /// One answer of this subject.
    struct Attempt: Equatable {
        let questionID: String
        let timestamp: Date
        let correct: Bool
        let year: Int?
    }

    /// One finished single-subject mock.
    struct Exam: Equatable {
        let date: Date
        let score: Int
        let counted: Bool
        /// Seconds of each answered question (zero entries are ignored).
        let seconds: [Double]
    }

    /// Scheduling state of one question in the active pool.
    struct Card: Equatable {
        let isScheduled: Bool
        let isDue: Bool
        let mastered: Bool
        let reason: String?
    }

    struct ScorePoint: Equatable {
        let date: Date
        let score: Int
        let counted: Bool
    }

    struct YearRate: Equatable {
        let year: Int
        let correct: Int
        let total: Int
        var percent: Int? { SubjectAnalysis.percent(correct: correct, total: total) }
        var eligible: Bool { total >= SubjectAnalysis.yearMinAttempts }
    }

    struct StatusCounts: Equatable {
        var due = 0
        var learning = 0
        var mastered = 0
        var total: Int { due + learning + mastered }
    }

    struct FrequentWrong: Equatable {
        let questionID: String
        let wrongCount: Int
        let lastWrong: Date
    }

    // MARK: Aggregations

    /// Rounded percentage; anything short of every answer correct shows at most 99.
    static func percent(correct: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        let p = Int((Double(correct) / Double(total) * 100).rounded())
        return correct < total ? min(99, p) : p
    }

    /// Attempts made by finished mocks that do not count toward scores (keyed by question and submission time).
    struct AttemptKey: Hashable {
        let questionID: String
        let timestamp: Date
    }

    /// Every finished mock in date order; uncounted ones stay in the list, flagged.
    static func scoreTrend(_ exams: [Exam]) -> [ScorePoint] {
        exams.sorted { $0.date < $1.date }.map { ScorePoint(date: $0.date, score: $0.score, counted: $0.counted) }
    }

    /// Latest and previous counted score.
    static func latestCounted(_ trend: [ScorePoint]) -> (latest: Int, previous: Int?)? {
        let counted = trend.filter(\.counted)
        guard let last = counted.last else { return nil }
        return (last.score, counted.count >= 2 ? counted[counted.count - 2].score : nil)
    }

    /// New vs review accuracy of this subject since `since`, classified against the full history.
    static func accuracy(_ attempts: [Attempt], since: Date) -> AccuracySplit.Result {
        AccuracySplit.compute(attempts.map {
            AttemptFact(questionID: $0.questionID, timestamp: $0.timestamp, correct: $0.correct, fromExam: false)
        }, since: since)
    }

    /// Open (unmastered) mistakes per most recent wrong-answer reason, in the answer-sheet order; zeros are kept.
    static func reasonCounts(_ cards: [Card]) -> [(reason: String, count: Int)] {
        let open = cards.filter { $0.isScheduled && !$0.mastered }
        let counts = Dictionary(grouping: open.compactMap(\.reason), by: { $0 }).mapValues(\.count)
        return MistakeReason.all.map { ($0, counts[$0] ?? 0) }
    }

    /// Accuracy of every attempt per exam year, 106–115.
    static func yearRates(_ attempts: [Attempt]) -> [YearRate] {
        var correct: [Int: Int] = [:], total: [Int: Int] = [:]
        for a in attempts {
            guard let y = a.year else { continue }
            total[y, default: 0] += 1
            if a.correct { correct[y, default: 0] += 1 }
        }
        return yearRange.map { YearRate(year: $0, correct: correct[$0] ?? 0, total: total[$0] ?? 0) }
    }

    /// The two weakest years among those with at least `yearMinAttempts` answers,
    /// only when at least three years qualify (otherwise nothing stands out).
    static func weakestYears(_ rates: [YearRate]) -> [Int] {
        let withData = rates.filter(\.eligible)
        guard withData.count >= 3 else { return [] }
        return withData.sorted { (Double($0.correct) / Double($0.total), $0.year) < (Double($1.correct) / Double($1.total), $1.year) }
            .prefix(2).map(\.year).sorted()
    }

    /// 待複習 (open, due today) / 學習中 (open, not due) / 熟練. 待複習 + 學習中 are the open mistakes,
    /// the same set 「練這科的錯題」 practices; a mastered card stays 熟練 even on its pre-exam review day.
    static func statusCounts(_ cards: [Card]) -> StatusCounts {
        var s = StatusCounts()
        for c in cards where c.isScheduled {
            if c.mastered { s.mastered += 1 } else if c.isDue { s.due += 1 } else { s.learning += 1 }
        }
        return s
    }

    /// Average seconds per answered question across mocks; nil without timing data.
    static func averageSeconds(_ exams: [Exam]) -> Int? {
        let values = exams.flatMap(\.seconds).filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }

    /// Questions answered wrong at least twice, most wrong first, then most recent.
    static func frequentWrong(_ attempts: [Attempt]) -> [FrequentWrong] {
        Dictionary(grouping: attempts.filter { !$0.correct }, by: \.questionID)
            .compactMap { id, list -> FrequentWrong? in
                guard list.count >= frequentWrongThreshold else { return nil }
                return FrequentWrong(questionID: id, wrongCount: list.count, lastWrong: list.map(\.timestamp).max()!)
            }
            .sorted { ($0.wrongCount, $0.lastWrong, $0.questionID) > ($1.wrongCount, $1.lastWrong, $1.questionID) }
            .prefix(frequentWrongLimit).map { $0 }
    }

    struct WeakUnit: Equatable {
        let unit: ConceptUnit
        let rate: UnitAccuracy.Rate
        /// Questions in the whole bank with this primary unit.
        let questionCount: Int
        var fewQuestions: Bool { questionCount < SubjectAnalysis.fewQuestionsThreshold }
    }

    /// The lowest-accuracy units among `units` with enough answers; ties by unit code (1.9 before 1.10).
    static func weakUnits(_ units: [ConceptUnit], rates: [String: UnitAccuracy.Rate],
                          questionCounts: [String: Int]) -> [WeakUnit] {
        units.compactMap { u -> WeakUnit? in
            guard let r = rates[u.id], r.total >= weakUnitMinAttempts else { return nil }
            return WeakUnit(unit: u, rate: r, questionCount: questionCounts[u.id] ?? 0)
        }
        .sorted { a, b in
            let lhs = a.rate.correct * b.rate.total, rhs = b.rate.correct * a.rate.total
            if lhs != rhs { return lhs < rhs }
            return a.unit.id.localizedStandardCompare(b.unit.id) == .orderedAscending
        }
        .prefix(weakUnitLimit).map { $0 }
    }

    // MARK: Report

    struct Report {
        let subject: String
        let trend: [ScorePoint]
        let latest: Int?
        let delta: Int?
        let accuracy: AccuracySplit.Result
        let reasons: [(reason: String, count: Int)]
        let years: [YearRate]
        let weakest: [Int]
        let status: StatusCounts
        let seen: Int
        let poolSize: Int
        let averageSeconds: Int?
        let frequent: [FrequentWrong]
        let openMistakeIDs: [String]
        let weakUnits: [WeakUnit]

        var reasonTotal: Int { reasons.map(\.count).reduce(0, +) }
        var hasAnswers: Bool { years.contains { $0.total > 0 } }
    }
}

extension StudyStore {
    /// Gathers the facts of one subject and runs every aggregation.
    /// `years` narrows every question statistic to questions of those years; mock-exam scores are never filtered.
    func subjectReport(subject: String, bank: QuestionBank, includeSpecial: Bool, accuracyDays: Int = StudyLogSummary.accuracyDays,
                       years: YearSelection = .all, now: Date = .now) -> SubjectAnalysis.Report {
        let cal = scheduler.calendar
        let pool = subjectPool(subject, bank: bank, includeSpecial: includeSpecial).filter { years.contains($0.year) }
        let poolIDs = Set(pool.map(\.id))
        func inYears(_ id: String) -> Bool { years.mode == .all || bank.byID[id].map { years.contains($0.year) } == true }
        let every = allAttempts().filter { inYears($0.questionID) }
        let finished = finishedExams()
        let isCounted = countedAttemptFilter(finished)
        let attempts = every.filter { $0.subject == subject }.map {
            SubjectAnalysis.Attempt(questionID: $0.questionID, timestamp: $0.timestamp, correct: $0.correct,
                                    year: bank.byID[$0.questionID]?.year)
        }
        let countedAttempts = every.filter { $0.subject == subject && isCounted($0) }.map {
            SubjectAnalysis.Attempt(questionID: $0.questionID, timestamp: $0.timestamp, correct: $0.correct,
                                    year: bank.byID[$0.questionID]?.year)
        }
        let records = allRecords().filter { $0.subject == subject && poolIDs.contains($0.questionID) }
        let preExam = PreExamReviewPlanner.plan(records: allRecords(), scheduler: scheduler, now: now)
        let cards = records.map { r in
            // 確認題 are not mistakes: they stay out of 待複習／學習中／熟練 and the reason counts.
            SubjectAnalysis.Card(isScheduled: r.schedule.isMistake,
                                 isDue: scheduler.isDue(r.schedule, on: now, reviewDue: preExam[r.questionID]),
                                 mastered: r.isMastered(using: scheduler, at: now),
                                 reason: r.lastReason)
        }
        let exams = finished.filter { $0.subject == subject }.map { e in
            SubjectAnalysis.Exam(date: e.finishedAt ?? e.startedAt, score: e.score, counted: e.countsTowardScores,
                                 seconds: zip(e.answers, e.seconds).compactMap { $0.isEmpty ? nil : $1 })
        }
        let trend = SubjectAnalysis.scoreTrend(exams)
        let scores = SubjectAnalysis.latestCounted(trend)
        let years = SubjectAnalysis.yearRates(countedAttempts)
        let since = cal.date(byAdding: .day, value: -accuracyDays, to: cal.startOfDay(for: now))!
        return SubjectAnalysis.Report(
            subject: subject, trend: trend, latest: scores?.latest,
            delta: scores.flatMap { s in s.previous.map { s.latest - $0 } },
            accuracy: SubjectAnalysis.accuracy(attempts, since: since),
            reasons: SubjectAnalysis.reasonCounts(cards), years: years, weakest: SubjectAnalysis.weakestYears(years),
            status: SubjectAnalysis.statusCounts(cards), seen: records.count, poolSize: pool.count,
            averageSeconds: SubjectAnalysis.averageSeconds(exams),
            frequent: SubjectAnalysis.frequentWrong(attempts.filter { poolIDs.contains($0.questionID) }),
            openMistakeIDs: openMistakeIDs(subject: subject, bank: bank, includeSpecial: includeSpecial, now: now)
                .filter(inYears),
            weakUnits: SubjectAnalysis.weakUnits(
                bank.units(of: subject),
                rates: UnitAccuracy.compute(attempts: every.filter(isCounted).map { ($0.questionID, $0.correct) }, bank: bank),
                questionCounts: Dictionary(grouping: bank.questions.compactMap(\.primaryConcept), by: { $0 }).mapValues(\.count)))
    }
}

extension StudyStore {
    /// Answers of uncounted mocks (too few answered, 錯題加強) stay out of the year and unit analysis.
    func countedAttemptFilter(_ finished: [MockExam]) -> (AttemptRecord) -> Bool {
        var uncounted = Set<SubjectAnalysis.AttemptKey>()
        for e in finished where !e.countsTowardScores {
            guard let t = e.finishedAt else { continue }
            for id in e.questionIDs { uncounted.insert(.init(questionID: id, timestamp: t)) }
        }
        return { a in
            a.source != AttemptRecord.examSource || !uncounted.contains(.init(questionID: a.questionID, timestamp: a.timestamp))
        }
    }

    /// The weakest unit of all subjects, by the 單科分析 「弱的單元」 rule; nil until a unit has enough answers.
    func weakestUnit(bank: QuestionBank) -> SubjectAnalysis.WeakUnit? {
        let isCounted = countedAttemptFilter(finishedExams())
        let rates = UnitAccuracy.compute(attempts: allAttempts().filter(isCounted).map { ($0.questionID, $0.correct) },
                                         bank: bank)
        return SubjectAnalysis.weakUnits(
            Subjects.all.flatMap(bank.units(of:)), rates: rates,
            questionCounts: Dictionary(grouping: bank.questions.compactMap(\.primaryConcept), by: { $0 }).mapValues(\.count)
        ).first
    }
}

extension AccuracySplit.Rate {
    /// Display percentage: short of every answer correct shows at most 99.
    var shownPercent: Int? { SubjectAnalysis.percent(correct: correct, total: total) }
}
