import Foundation

/// 「題目有誤」: a report about the question itself (not the AI explanation). Sent as a `question_report` usage event,
/// so it rides the offline queue and its retries.
enum QuestionReport {
    enum Category: String, CaseIterable, Identifiable {
        case stem, options, figure, answer, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stem: "題目文字有誤"
            case .options: "選項有誤"
            case .figure: "圖片缺漏或錯誤"
            case .answer: "答案有疑問"
            case .other: "其他"
            }
        }
    }

    static let maxNoteLength = 300
    static let eventType = "question_report"
    /// Question ids reported on this device (local only; shows 「已回報」).
    static let reportedKey = "reportedQuestionIDs"

    /// Event fields; an empty note is left out.
    static func fields(questionID: String, subject: String, category: Category, note: String) -> [String: Any] {
        var fields: [String: Any] = ["qid": questionID, "subject": subject, "category": category.rawValue]
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNoteLength))
        if !trimmed.isEmpty { fields["note"] = trimmed }
        return fields
    }

    @MainActor
    static func submit(_ q: Question, category: Category, note: String, log: UsageLog? = nil,
                       defaults: UserDefaults = .standard) {
        (log ?? .shared).log(eventType, fields(questionID: q.id, subject: q.subject, category: category, note: note))
        var ids = Set(defaults.stringArray(forKey: reportedKey) ?? [])
        ids.insert(q.id)
        defaults.set(Array(ids).sorted(), forKey: reportedKey)
    }

    static func isReported(_ questionID: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: reportedKey) ?? []).contains(questionID)
    }
}
