import Foundation
import SwiftData

// Schema V1 is frozen at the original shipped shape. Do not edit these definitions.


extension SchemaV1 {
@Model
final class QuestionRecord {
    @Attribute(.unique) var questionID: String
    var subject: String
    var stage: Int
    var dueDate: Date?
    var mastered: Bool
    /// Most recent wrong-answer reason, if any.
    var lastReason: String?
    var firstSeen: Date
    var lastAnswered: Date
    /// The latest wrong answer was marked 「我原本很確定」.
    var lastConfident: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \AttemptRecord.record)
    var attempts: [AttemptRecord] = []

    init(questionID: String, subject: String, now: Date) {
        self.questionID = questionID
        self.subject = subject
        self.stage = 0
        self.dueDate = nil
        self.mastered = false
        self.lastReason = nil
        self.firstSeen = now
        self.lastAnswered = now
    }

    var schedule: ScheduleState {
        get { ScheduleState(stage: stage, due: dueDate, mastered: mastered) }
        set {
            stage = newValue.stage
            dueDate = newValue.due
            mastered = newValue.mastered
        }
    }

    /// In the mistake book: scheduled and not yet mastered.
    var isOpenMistake: Bool { schedule.isScheduled }
}
}

extension SchemaV1 {
@Model
final class AttemptRecord {
    var questionID: String
    var subject: String
    var timestamp: Date
    var chosen: String
    var correct: Bool
    var reason: String?
    var unsure: Bool
    var stageBefore: Int
    var stageAfter: Int
    /// Wrong answer marked 「我原本很確定」 (hypercorrection candidates).
    var confident: Bool = false
    /// Where the answer came from; `AttemptRecord.examSource` for mock exams, nil for review and practice.
    var source: String?
    var record: QuestionRecord?

    static let examSource = "exam"

    init(questionID: String, subject: String, timestamp: Date, chosen: String, correct: Bool,
         reason: String?, unsure: Bool, stageBefore: Int, stageAfter: Int, source: String? = nil) {
        self.questionID = questionID
        self.subject = subject
        self.timestamp = timestamp
        self.chosen = chosen
        self.correct = correct
        self.reason = reason
        self.unsure = unsure
        self.stageBefore = stageBefore
        self.stageAfter = stageAfter
        self.source = source
    }
}
}

extension SchemaV1 {
@Model
final class QuestionNote {
    @Attribute(.unique) var questionID: String
    var subject: String
    var bookmarked: Bool
    var text: String
    var updatedAt: Date

    init(questionID: String, subject: String, now: Date) {
        self.questionID = questionID
        self.subject = subject
        bookmarked = false
        text = ""
        updatedAt = now
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { !bookmarked && !hasText }
}
}

extension SchemaV1 {
@Model
final class MockExam {
    var examID: UUID
    var subject: String
    var modeRaw: String
    /// Session code of the paper for 整份歷屆; nil for mixed modes.
    var paperCode: String?
    /// "115 年 一般", "隨機混合", "錯題加強"
    var title: String
    var questionIDs: [String]
    /// Chosen letter per question; "" = unanswered.
    var answers: [String]
    var flags: [Bool]
    /// Wrong-answer reason per question; "" = none.
    var reasons: [String]
    /// Seconds spent on each question.
    var seconds: [Double]
    var currentIndex: Int
    /// Accumulated answering time in seconds (excluding pauses).
    var elapsed: Double
    var startedAt: Date
    var finishedAt: Date?
    var autoSubmitted: Bool
    var correctCount: Int
    var score: Int
    /// Shown option order per question, encoded by `OptionShuffle.encode` ("" = original order).
    /// Empty for exams created before shuffling existed and for whole-paper / full mocks.
    var optionOrders: [String] = []
    /// Set when this exam is one subject of a five-subject full mock.
    var fullMockID: UUID?
    /// Full-mock subjects are submitted first and only marked finished (scored, recorded) when all five are done.
    var submittedAt: Date?

    init(subject: String, mode: ExamMode, paperCode: String?, title: String, questionIDs: [String], now: Date) {
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

extension SchemaV1 {
@Model
final class FullMock {
    var fullID: UUID
    /// Session code, e.g. "113100".
    var code: String
    /// "113 年", "106 年 花東補辦"
    var label: String
    var startedAt: Date
    var finishedAt: Date?
    /// Set when a subject is submitted; the 10-minute break runs from here. nil before the first subject.
    var breakStartedAt: Date?

    init(code: String, label: String, now: Date) {
        fullID = UUID()
        self.code = code
        self.label = label
        startedAt = now
    }

    var isFinished: Bool { finishedAt != nil }
}
}

extension SchemaV1 {
@Model
final class AIExplanation {
    @Attribute(.unique) var questionID: String
    var text: String
    var version: Int
    /// Server timestamp (ISO 8601 string as sent).
    var createdAt: String
    var savedAt: Date
    /// JSON-encoded `[AIChatTurn]`.
    var followupData: Data
    /// 「解析有誤」 was sent for this version.
    var reportedWrong: Bool

    init(questionID: String, text: String, version: Int, createdAt: String, now: Date = .now) {
        self.questionID = questionID
        self.text = text
        self.version = version
        self.createdAt = createdAt
        self.savedAt = now
        self.followupData = Data("[]".utf8)
        self.reportedWrong = false
    }

    var followups: [AIChatTurn] {
        get { (try? JSONDecoder().decode([AIChatTurn].self, from: followupData)) ?? [] }
        set { followupData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }
}
}
