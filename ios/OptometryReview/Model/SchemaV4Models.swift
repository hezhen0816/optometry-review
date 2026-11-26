import Foundation
import SwiftData

// Schema V4 is frozen at the 0.2.x shape (last local-only schema). Never change its persisted fields.
// QuestionNote and AIExplanation did not change in V5 and are shared with it (Records.swift, AIExplain.swift).

extension SchemaV4 {
@Model
final class QuestionRecord {
    var questionID: String = ""
    var subject: String = ""
    var stage: Int = 0
    var dueDate: Date? = nil
    var stability: Double = 0
    var difficulty: Double = 0
    var reps: Int = 0
    var lapses: Int = 0
    var lastReview: Date? = nil
    var dueCorrectCount: Int = 0
    var fsrsVersion: Int = 0
    var parked: Bool = false
    var parkedAt: Date? = nil
    var resumeDueDate: Date? = nil
    var lastReason: String? = nil
    var firstSeen: Date = Date(timeIntervalSince1970: 0)
    var lastAnswered: Date = Date(timeIntervalSince1970: 0)
    var lastConfident: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \AttemptRecord.record)
    var attempts: [AttemptRecord]? = []

    init(questionID: String, subject: String, now: Date) {
        self.questionID = questionID
        self.subject = subject
        self.firstSeen = now
        self.lastAnswered = now
    }
}
}

extension SchemaV4 {
@Model
final class AttemptRecord {
    var questionID: String = ""
    var subject: String = ""
    var timestamp: Date = Date(timeIntervalSince1970: 0)
    var chosen: String = ""
    var correct: Bool = false
    var reason: String? = nil
    var unsure: Bool = false
    var retry: Bool = false
    var answerOrder: Int = 0
    var masteredBefore: Bool? = nil
    var stageBefore: Int = 0
    var stageAfter: Int = 0
    var confident: Bool = false
    var source: String? = nil
    var record: QuestionRecord? = nil

    init(questionID: String, subject: String, timestamp: Date, chosen: String, correct: Bool,
         reason: String?, unsure: Bool, source: String? = nil) {
        self.questionID = questionID
        self.subject = subject
        self.timestamp = timestamp
        self.chosen = chosen
        self.correct = correct
        self.reason = reason
        self.unsure = unsure
        self.source = source
    }
}
}

extension SchemaV4 {
@Model
final class MockExam {
    var examID: UUID = UUID()
    var subject: String = ""
    var modeRaw: String = ""
    var paperCode: String? = nil
    var title: String = ""
    var questionIDs: [String] = []
    var answers: [String] = []
    var flags: [Bool] = []
    var reasons: [String] = []
    var seconds: [Double] = []
    var currentIndex: Int = 0
    var elapsed: Double = 0
    var startedAt: Date = Date(timeIntervalSince1970: 0)
    var finishedAt: Date? = nil
    var autoSubmitted: Bool = false
    var correctCount: Int = 0
    var score: Int = 0
    var optionOrders: [String] = []
    var fullMockID: UUID? = nil
    var submittedAt: Date? = nil

    init(subject: String, modeRaw: String, title: String, questionIDs: [String], now: Date) {
        self.subject = subject
        self.modeRaw = modeRaw
        self.title = title
        self.questionIDs = questionIDs
        startedAt = now
    }
}
}

extension SchemaV4 {
@Model
final class FullMock {
    var fullID: UUID = UUID()
    var code: String = ""
    var label: String = ""
    var startedAt: Date = Date(timeIntervalSince1970: 0)
    var finishedAt: Date? = nil
    var breakStartedAt: Date? = nil

    init(code: String, label: String, now: Date) {
        self.code = code
        self.label = label
        startedAt = now
    }
}
}
