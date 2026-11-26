import Foundation

/// Reports on AI questions and their figures. Both travel as `question_report` usage events (the server stores
/// the extra fields as they come); the qid is the `ai:` id. Nothing is sent when 使用紀錄回傳 is off, so the
/// local state (reported ids, hidden figures) is written either way.
enum AIReport {
    enum FigureReason: String, CaseIterable, Identifiable {
        case direction, numbers, steps, overlap, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .direction: "方向畫錯（例如基底朝向、箭頭）"
            case .numbers: "數字或標字錯"
            case .steps: "和解題步驟對不上"
            case .overlap: "標字重疊、看不清楚"
            case .other: "其他"
            }
        }
    }

    /// Event fields of a 「圖有誤」 report: figure type, parameters and the reason; never the learner's answer.
    static func figureFields(question: AIQuestion, reason: FigureReason, note: String) -> [String: Any] {
        var fields: [String: Any] = ["qid": question.id, "subject": question.subject, "category": "figure",
                                     "source": AttemptRecord.aiSource, "figureReason": reason.rawValue]
        if let spec = question.figure {
            fields["figureType"] = spec.type
            var params: [String: Any] = [:]
            for (k, v) in spec.params {
                switch v {
                case .number(let d): params[k] = d
                case .text(let s): params[k] = s
                }
            }
            fields["figureParams"] = params
        }
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(QuestionReport.maxNoteLength))
        if !trimmed.isEmpty { fields["note"] = trimmed }
        return fields
    }

    /// Event fields of a 「題目有誤」 report of an AI question.
    static func questionFields(question: AIQuestion, category: QuestionReport.Category, note: String) -> [String: Any] {
        var fields = QuestionReport.fields(questionID: question.id, subject: question.subject, category: category, note: note)
        fields["source"] = AttemptRecord.aiSource
        return fields
    }

    @MainActor
    static func submitFigure(_ q: AIQuestion, reason: FigureReason, note: String, log: UsageLog? = nil,
                             defaults: UserDefaults = .standard) {
        (log ?? .shared).log(QuestionReport.eventType, figureFields(question: q, reason: reason, note: note))
        AIPractice.hideFigure(q.id, defaults: defaults)
    }

    @MainActor
    static func submitQuestion(_ q: AIQuestion, category: QuestionReport.Category, note: String, log: UsageLog? = nil,
                               defaults: UserDefaults = .standard) {
        (log ?? .shared).log(QuestionReport.eventType, questionFields(question: q, category: category, note: note))
        var ids = Set(defaults.stringArray(forKey: QuestionReport.reportedKey) ?? [])
        ids.insert(q.id)
        defaults.set(Array(ids).sorted(), forKey: QuestionReport.reportedKey)
    }
}
