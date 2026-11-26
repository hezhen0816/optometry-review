import Foundation
import SwiftData

/// Wrong-answer reasons shown on the answer sheet and in the mistake book filter.
enum MistakeReason {
    static let all = ["觀念不懂", "粗心", "背錯", "算錯"]
}

/// Per-question learning state. Created the first time a question is answered.
extension SchemaV5 {
@Model
final class QuestionRecord {
    /// Synced identity (V5). The last tie-break when two devices merge duplicate cards: local persistent IDs differ
    /// per device and CloudKit keeps dates only to the millisecond, so neither can decide. Nil only for cards from
    /// before 0.3.0; `StudyDeduplication` fills them.
    var cardID: UUID? = nil
    /// Created by the app-open repair for attempts whose card never arrived; a real card always wins a merge.
    var createdByRepair: Bool = false
    var questionID: String = ""
    var subject: String = ""
    /// Legacy value retained for migration only. Never used for scheduling.
    var stage: Int = 0
    /// Raw FSRS due date, before ExamDatePolicy. Use reviewStatus for presentation.
    var dueDate: Date? = nil
    var stability: Double = 0
    var difficulty: Double = 0
    var reps: Int = 0
    var lapses: Int = 0
    var lastReview: Date? = nil
    var dueCorrectCount: Int = 0
    /// Per-record marker also covers replayed records that remain unscheduled.
    var fsrsVersion: Int = 0
    var parked: Bool = false
    /// When `parked` last changed (park or unpark). Merging duplicate cards takes the parked state of the newest.
    /// Unparks before 0.3.0 cleared it to nil, which merges as the oldest.
    var parkedAt: Date? = nil
    /// Explicit next review after unpark, until a scheduling answer consumes it. Overrides exam rest days.
    var resumeDueDate: Date? = nil
    /// Most recent wrong-answer reason, if any.
    var lastReason: String? = nil
    var firstSeen: Date = Date(timeIntervalSince1970: 0)
    var lastAnswered: Date = Date(timeIntervalSince1970: 0)
    /// The latest wrong answer was marked 「我原本很確定」. Retired from the UI; kept for stored data.
    var lastConfident: Bool = false
    /// Nullify, not cascade: with iCloud sync another device may delete a duplicate card (after merging it there)
    /// while attempts here still point at it. Attempts are facts and must survive; `StudyDeduplication` reattaches
    /// orphans. (The delete rule is not part of the store's version hash.)
    @Relationship(deleteRule: .nullify, inverse: \AttemptRecord.record)
    var attempts: [AttemptRecord]? = []

    init(questionID: String, subject: String, now: Date) {
        self.cardID = UUID()
        self.questionID = questionID
        self.subject = subject
        self.stage = 0
        self.dueDate = nil
        self.lastReason = nil
        self.firstSeen = now
        self.lastAnswered = now
    }

    var schedule: ReviewSchedule {
        get {
            ReviewSchedule(stability: stability, difficulty: difficulty, reps: reps, lapses: lapses,
                           lastReview: lastReview, due: dueDate, dueCorrectCount: dueCorrectCount)
        }
        set {
            stability = newValue.stability
            difficulty = newValue.difficulty
            reps = newValue.reps
            lapses = newValue.lapses
            lastReview = newValue.lastReview
            dueDate = newValue.due
            dueCorrectCount = newValue.dueCorrectCount
        }
    }

    @MainActor
    func reviewStatus(using scheduler: Scheduler, at now: Date = .now, reviewDue: ReviewDue? = nil) -> ReviewStatus {
        if parked {
            return ReviewStatus(nextReviewDate: nil, daysUntilNextReview: nil, mastered: false,
                                memoryStrength: scheduler.memoryStrength(schedule, at: now),
                                stabilityDays: stability, isScheduled: false)
        }
        let due = resumeReviewDue ?? reviewDue ?? PreExamReviewPlanner.reviewDue(for: self, scheduler: scheduler, now: now)
        return scheduler.status(schedule, at: now, reviewDue: due)
    }

    var resumeReviewDue: ReviewDue? { resumeDueDate.map { .resumed($0) } }

    func isMastered(using scheduler: Scheduler, at now: Date = .now) -> Bool {
        !parked && scheduler.isMastered(schedule, at: now)
    }

    func isOpenMistake(using scheduler: Scheduler, at now: Date = .now) -> Bool {
        !parked && scheduler.isOpenMistake(schedule, at: now)
    }

    /// Convenience for existing callers; explicit scheduler/time APIs are preferred.
    var isOpenMistake: Bool { isOpenMistake(using: Scheduler(examDate: SettingsKey.examDateValue)) }
}
}
typealias QuestionRecord = SchemaV5.QuestionRecord

/// Full answer history, also used for the one-time FSRS replay.
extension SchemaV5 {
@Model
final class AttemptRecord {
    /// Synced identity (V5): decides which copy survives when the same answer exists twice (e.g. imported from a
    /// file while iCloud was restoring it). Nil only for answers from before 0.3.0; `StudyDeduplication` fills them.
    var attemptID: UUID? = nil
    var questionID: String = ""
    var subject: String = ""
    var timestamp: Date = Date(timeIntervalSince1970: 0)
    var chosen: String = ""
    var correct: Bool = false
    var reason: String? = nil
    var unsure: Bool = false
    /// Attribution only; retry eligibility and queues are always rebuilt from outcomes.
    var retry: Bool = false
    /// Preserves within-question ordering when taps share a timestamp; legacy rows use zero.
    var answerOrder: Int = 0
    /// Live pre-answer mastery captures unpark/exam-policy changes that cannot be inferred from old histories.
    /// Nil legacy values are reconstructed by replay.
    var masteredBefore: Bool? = nil
    /// Legacy fixed-stage history, preserved on migration; new FSRS attempts leave these at zero.
    var stageBefore: Int = 0
    var stageAfter: Int = 0
    /// Wrong answer marked 「我原本很確定」 (hypercorrection candidates).
    var confident: Bool = false
    /// Where the answer came from; `AttemptRecord.examSource` for mock exams, nil for review and practice.
    var source: String? = nil
    /// Inverse of QuestionRecord.attempts, declared on the collection side.
    var record: QuestionRecord? = nil

    static let examSource = "exam"
    /// AI-generated questions (docs/AI出題與圖解.md §4): never get a QuestionRecord, never enter dedup or replay.
    static let aiSource = "ai"
    static let aiQuestionPrefix = "ai:"

    static func isAIQuestion(_ questionID: String) -> Bool { questionID.hasPrefix(aiQuestionPrefix) }

    var isAI: Bool { source == Self.aiSource || Self.isAIQuestion(questionID) }

    init(questionID: String, subject: String, timestamp: Date, chosen: String, correct: Bool,
         reason: String?, unsure: Bool, stageBefore: Int = 0, stageAfter: Int = 0, source: String? = nil) {
        self.attemptID = UUID()
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
typealias AttemptRecord = SchemaV5.AttemptRecord

/// Bookmark and note of one question. Kept apart from `QuestionRecord` so unanswered questions can be bookmarked too.
extension SchemaV4 {
@Model
final class QuestionNote {
    var questionID: String = ""
    var subject: String = ""
    var bookmarked: Bool = false
    var text: String = ""
    var updatedAt: Date = Date(timeIntervalSince1970: 0)

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
typealias QuestionNote = SchemaV4.QuestionNote
