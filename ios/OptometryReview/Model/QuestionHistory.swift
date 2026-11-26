import Foundation

/// Read-only summary of one question's answer history for the question detail (錯題本 card tap).
/// Building it never writes: viewing a question is not an attempt.
struct QuestionHistory: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: Int
        let date: Date
        /// 「答對」, 「答對・猜的」, 「答錯」, 「看解答」; mock answers add 「模擬考」.
        let outcome: String
        let correct: Bool
        let reason: String?
    }

    /// Latest 錯因 stored on the record.
    let latestReason: String?
    /// Newest first.
    let entries: [Entry]

    static let empty = QuestionHistory(latestReason: nil, entries: [])

    init(latestReason: String?, entries: [Entry]) {
        self.latestReason = latestReason
        self.entries = entries
    }

    init(record: QuestionRecord?) {
        guard let record else { self = .empty; return }
        let attempts = (record.attempts ?? []).sorted {
            ($0.timestamp, $0.answerOrder) > ($1.timestamp, $1.answerOrder)
        }
        latestReason = record.lastReason
        entries = attempts.enumerated().map { i, a in
            let exam = a.source == AttemptRecord.examSource
            var outcome: String
            if a.correct { outcome = a.unsure ? "答對・猜的" : "答對" }
            else if a.chosen.isEmpty && !exam { outcome = "看解答" }
            else { outcome = exam && a.chosen.isEmpty ? "未作答" : "答錯" }
            if exam { outcome = "模擬考 " + outcome }
            return Entry(id: i, date: a.timestamp, outcome: outcome, correct: a.correct, reason: a.correct ? nil : a.reason)
        }
    }

    @MainActor
    static func load(questionID: String, store: StudyStore) -> QuestionHistory {
        QuestionHistory(record: store.record(for: questionID))
    }
}
