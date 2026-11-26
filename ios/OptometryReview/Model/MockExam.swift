import Foundation
import SwiftData

enum ExamMode: String, CaseIterable, Identifiable {
    case wholePaper = "整份歷屆"
    case random = "隨機混合"
    case mistakes = "錯題加強"
    var id: String { rawValue }
}

enum ExamRules {
    static let questionCount = 50
    static let durationSeconds: Double = 60 * 60
    static let pointsPerQuestion = 2
    static let referenceLine = 60
}

/// One single-subject mock exam, in progress or finished. Progress is saved on every change so it can be resumed.
extension SchemaV5 {
@Model
final class MockExam {
    /// Synced row identity (V5). `examID` is copied by import, so the same exam can exist twice (imported while
    /// iCloud was restoring it); this decides which copy stays. Nil only before 0.3.0; `StudyDeduplication` fills it.
    var syncID: UUID? = nil
    var examID: UUID = UUID()
    var subject: String = ""
    var modeRaw: String = ""
    /// Session code of the paper for 整份歷屆; nil for mixed modes.
    var paperCode: String? = nil
    /// "115 年 一般", "隨機混合", "錯題加強"
    var title: String = ""
    var questionIDs: [String] = []
    /// Chosen letter per question; "" = unanswered.
    var answers: [String] = []
    var flags: [Bool] = []
    /// Wrong-answer reason per question; "" = none.
    var reasons: [String] = []
    /// Seconds spent on each question.
    var seconds: [Double] = []
    var currentIndex: Int = 0
    /// Accumulated answering time in seconds (excluding pauses).
    var elapsed: Double = 0
    var startedAt: Date = Date(timeIntervalSince1970: 0)
    var finishedAt: Date? = nil
    var autoSubmitted: Bool = false
    var correctCount: Int = 0
    var score: Int = 0
    /// Shown option order per question, encoded by `OptionShuffle.encode` ("" = original order).
    /// Empty for exams created before shuffling existed and for whole-paper / full mocks.
    var optionOrders: [String] = []
    /// Set when this exam is one subject of a five-subject full mock.
    var fullMockID: UUID? = nil
    /// Full-mock subjects are submitted first and only marked finished (scored, recorded) when all five are done.
    var submittedAt: Date? = nil

    init(subject: String, mode: ExamMode, paperCode: String?, title: String, questionIDs: [String], now: Date) {
        syncID = UUID()
        examID = UUID()
        self.subject = subject
        modeRaw = mode.rawValue
        self.paperCode = paperCode
        self.title = title
        self.questionIDs = questionIDs
        answers = Array(repeating: "", count: questionIDs.count)
        flags = Array(repeating: false, count: questionIDs.count)
        reasons = Array(repeating: "", count: questionIDs.count)
        seconds = Array(repeating: 0, count: questionIDs.count)
        currentIndex = 0
        elapsed = 0
        startedAt = now
        finishedAt = nil
        autoSubmitted = false
        correctCount = 0
        score = 0
    }

    var mode: ExamMode { ExamMode(rawValue: modeRaw) ?? .wholePaper }
    var isFinished: Bool { finishedAt != nil }
    /// Finished, or submitted as part of an unfinished full mock.
    var isSubmitted: Bool { finishedAt != nil || submittedAt != nil }
    var isFullMockPart: Bool { fullMockID != nil }

    /// Shown option order of question `i`.
    func optionOrder(at i: Int) -> OptionOrder {
        i < optionOrders.count ? OptionOrder(encoded: optionOrders[i]) : .original
    }
    var answeredCount: Int { answers.prefix(questionIDs.count).filter { !$0.isEmpty }.count }
    /// Eligibility is per subject, including subjects of a full mock. History also requires `isFinished`.
    var countsTowardScores: Bool {
        mode != .mistakes && !questionIDs.isEmpty && answeredCount * 5 >= questionIDs.count * 4
    }
    /// Answers needed for `countsTowardScores`: 80 % of the questions, rounded up (40 of 50).
    var countingThreshold: Int { (questionIDs.count * 4 + 4) / 5 }
    /// Why a finished exam is left out of the score trend and pass projection; nil when it counts.
    var uncountedReason: String? {
        if countsTowardScores { return nil }
        return mode == .mistakes ? "錯題加強卷" : "作答未滿 \(countingThreshold) 題"
    }
    var flaggedCount: Int { flags.filter { $0 }.count }
}
}
typealias MockExam = SchemaV5.MockExam

/// Exam result counts. Each correct answer is worth 2 points; unanswered questions score nothing.
struct ExamScore: Equatable {
    var correct: Int
    var wrong: Int
    var unanswered: Int
    var score: Int { correct * ExamRules.pointsPerQuestion }
}

enum ExamScoring {
    /// Correct when answered and the letter is in the (corrected) answer list. All-credit questions list every letter.
    static func isCorrect(answer: String, question: Question) -> Bool {
        !answer.isEmpty && Grading.isCorrect(chosen: answer, question: question)
    }

    static func score(questions: [Question], answers: [String]) -> ExamScore {
        var s = ExamScore(correct: 0, wrong: 0, unanswered: 0)
        for (i, q) in questions.enumerated() {
            let a = i < answers.count ? answers[i] : ""
            if a.isEmpty {
                s.unanswered += 1
            } else if isCorrect(answer: a, question: q) {
                s.correct += 1
            } else {
                s.wrong += 1
            }
        }
        return s
    }
}

/// Countdown arithmetic. The clock runs only while the exam screen is active (`resumedAt` set).
enum ExamClock {
    static func elapsed(stored: Double, resumedAt: Date?, now: Date) -> Double {
        guard let resumedAt else { return stored }
        return stored + max(0, now.timeIntervalSince(resumedAt))
    }

    static func remaining(stored: Double, resumedAt: Date?, now: Date, limit: Double = ExamRules.durationSeconds) -> Double {
        max(0, limit - elapsed(stored: stored, resumedAt: resumedAt, now: now))
    }

    static func shouldAutoSubmit(stored: Double, resumedAt: Date?, now: Date, limit: Double = ExamRules.durationSeconds) -> Bool {
        remaining(stored: stored, resumedAt: resumedAt, now: now, limit: limit) <= 0
    }

    /// "57:40"; rounds up so the display reaches 00:00 exactly when time is over.
    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "51 分 20 秒"
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) 秒" }
        return s % 60 == 0 ? "\(s / 60) 分" : "\(s / 60) 分 \(s % 60) 秒"
    }
}

/// Question selection for single-subject mocks.
enum ExamBuilder {
    /// Newest general paper of the subject not yet taken as a whole-paper mock. Falls back to the newest paper.
    /// - Parameter papers: candidate papers of one subject.
    static func nextUntakenPaper(_ papers: [Paper], taken: Set<String>) -> Paper? {
        let sorted = papers.sorted { ($0.year, $0.code) > ($1.year, $1.code) }
        return sorted.first { !taken.contains($0.id) } ?? sorted.first
    }

    /// Never-attempted questions first (shuffled); questions seen before only fill the remaining slots.
    static func randomMix(pool: [String], seen: Set<String> = [], count: Int = ExamRules.questionCount,
                          using rng: inout some RandomNumberGenerator) -> [String] {
        let fresh = pool.filter { !seen.contains($0) }.shuffled(using: &rng)
        let old = pool.filter { seen.contains($0) }.shuffled(using: &rng)
        // Mixed again so the filled-in old questions are not all at the end.
        return Array((fresh + old).prefix(count)).shuffled(using: &rng)
    }

    /// Shown option orders for a new exam: shuffled for mixed modes, original for whole papers.
    static func optionOrders(for questions: [Question], mode: ExamMode,
                             using rng: inout some RandomNumberGenerator) -> [String] {
        questions.map { q in
            mode == .wholePaper ? "" : OptionShuffle.encode(OptionShuffle.order(for: q, using: &rng))
        }
    }

    /// Open mistakes first, then previously-missed questions, then unseen ones, up to `count`. No duplicates.
    static func mistakeFocus(open: [String], weak: [String], fresh: [String], count: Int = ExamRules.questionCount) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in open + weak + fresh where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
            if result.count == count { break }
        }
        return result
    }
}

/// Five-subject full mock bookkeeping. Each subject is a `MockExam` with `fullMockID == fullID`.
extension SchemaV5 {
@Model
final class FullMock {
    /// Synced row identity (V5); see `MockExam.syncID`.
    var syncID: UUID? = nil
    var fullID: UUID = UUID()
    /// Session code, e.g. "113100".
    var code: String = ""
    /// "113 年", "106 年 花東補辦"
    var label: String = ""
    var startedAt: Date = Date(timeIntervalSince1970: 0)
    var finishedAt: Date? = nil
    /// Set when a subject is submitted; the 10-minute break runs from here. nil before the first subject.
    var breakStartedAt: Date? = nil

    init(code: String, label: String, now: Date) {
        syncID = UUID()
        fullID = UUID()
        self.code = code
        self.label = label
        startedAt = now
    }

    var isFinished: Bool { finishedAt != nil }
}
}
typealias FullMock = SchemaV5.FullMock

enum FullMockRules {
    static let breakSeconds: Double = 10 * 60

    /// Remaining break time; 0 when over or not started.
    static func breakRemaining(startedAt: Date?, now: Date) -> Double {
        guard let startedAt else { return 0 }
        return max(0, breakSeconds - now.timeIntervalSince(startedAt))
    }

    /// Default session: newest one not fully taken (no finished full mock and not all five papers done as whole papers).
    static func defaultSession(_ sessions: [ExamSession], fullyTaken: Set<String>) -> ExamSession? {
        let complete = sessions.filter { $0.papers.count == Subjects.all.count }
        return complete.first { !fullyTaken.contains($0.code) } ?? complete.first
    }
}

/// National pass rule applied to a full mock: average ≥ 60 AND no subject at 0.
struct FullMockJudgment: Equatable {
    let scores: [Int]

    var average: Double { scores.isEmpty ? 0 : Double(scores.reduce(0, +)) / Double(scores.count) }
    var averageOK: Bool { average >= Double(ExamRules.referenceLine) }
    var noZero: Bool { !scores.contains(0) }
    var passed: Bool { scores.count == Subjects.all.count && averageOK && noZero }

    /// Average if the lowest subject below 60 were raised to 60 (for the hint line); nil when none is below.
    var averageIfLowestAt60: (index: Int, average: Double)? {
        guard let i = scores.indices.filter({ scores[$0] < ExamRules.referenceLine }).min(by: { scores[$0] < scores[$1] })
        else { return nil }
        var s = scores
        s[i] = ExamRules.referenceLine
        return (i, Double(s.reduce(0, +)) / Double(s.count))
    }
}

/// Pass projection from the latest single-subject scores: 五科平均 ≥ 60 and no subject at 0.
enum PassProjection {
    enum Result: Equatable {
        case pass(average: Double)
        case fail(average: Double, zeroSubjects: [String])
        case missing([String])

        /// Short verdict shown beside the 成績 average.
        var headline: String {
            switch self {
            case .pass: return "推估及格"
            case .fail(_, let zeros) where !zeros.isEmpty:
                return "未達：\(zeros.joined(separator: "、")) 0 分"
            case .fail: return "未達：平均低於 60"
            case .missing(let subjects): return "還不能推估：缺 \(subjects.count) 科"
            }
        }
    }

    static func evaluate(latest: [String: Int], subjects: [String] = Subjects.all) -> Result {
        let missing = subjects.filter { latest[$0] == nil }
        if !missing.isEmpty { return .missing(missing) }
        let scores = subjects.map { latest[$0]! }
        let average = Double(scores.reduce(0, +)) / Double(scores.count)
        let zeros = subjects.filter { latest[$0] == 0 }
        if average >= Double(ExamRules.referenceLine) && zeros.isEmpty { return .pass(average: average) }
        return .fail(average: average, zeroSubjects: zeros)
    }
}

/// Score history derived from finished mocks.
enum ScoreHistory {
    struct Entry: Equatable {
        let subject: String
        let score: Int
        let date: Date
        var countsTowardScores: Bool = true
    }

    struct Point: Equatable, Identifiable {
        var id: Date { date }
        let date: Date
        /// Average of the latest score of every subject taken so far.
        let average: Double
        let subjectCount: Int
    }

    static func latest(_ entries: [Entry]) -> [String: Int] {
        var map: [String: Entry] = [:]
        for e in entries where e.countsTowardScores && (map[e.subject]?.date ?? .distantPast) <= e.date { map[e.subject] = e }
        return map.mapValues(\.score)
    }

    /// Score of the mock before the latest one, per subject.
    static func previous(_ entries: [Entry]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (subject, list) in Dictionary(grouping: entries.filter(\.countsTowardScores), by: \.subject) {
            let sorted = list.sorted { $0.date < $1.date }
            if sorted.count >= 2 { result[subject] = sorted[sorted.count - 2].score }
        }
        return result
    }

    /// One point per finished mock: average of the latest score of each subject taken up to that mock.
    static func averageSeries(_ entries: [Entry]) -> [Point] {
        var latest: [String: Int] = [:]
        var points: [Point] = []
        for e in entries.filter(\.countsTowardScores).sorted(by: { $0.date < $1.date }) {
            latest[e.subject] = e.score
            let avg = Double(latest.values.reduce(0, +)) / Double(latest.count)
            points.append(Point(date: e.date, average: avg, subjectCount: latest.count))
        }
        return points
    }

    /// "63.2"
    static func format(_ average: Double) -> String {
        String(format: "%.1f", average)
    }

    /// The sole conversion from stored exams to score history. Uncounted exams remain in storage.
    static func entries(from exams: [MockExam]) -> [Entry] {
        exams.compactMap { exam in
            guard exam.countsTowardScores, let date = exam.finishedAt else { return nil }
            return Entry(subject: exam.subject, score: exam.score, date: date)
        }
    }
}
