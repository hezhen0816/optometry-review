import Foundation

/// Official subject names of the optometrist (驗光師) exam, in exam order. Kept verbatim.
enum Subjects {
    static let all: [String] = [
        "眼球解剖生理學與倫理法規",
        "視覺光學",
        "視光學",
        "隱形眼鏡學與配鏡學",
        "低視力學",
    ]
}

enum ExamKind {
    static let general = "一般"
    static let special = "特考"
}

/// One question from a parsed exam paper (題庫/轉檔/<code>/<s>_<subject>.json).
struct Question: Identifiable, Hashable {
    /// Stable id: "<code>_<subject>_<number>".
    let id: String
    let code: String
    let year: Int
    let examKind: String
    let subject: String
    let number: Int
    let stem: String
    /// Option texts keyed "A"..."D". Text may be empty when the options are images.
    let options: [String: String]
    /// Accepted answers (corrected answer takes precedence over the original).
    let answer: [String]
    let originalAnswer: String?
    let corrected: Bool
    let correctionNote: String?
    let allCredit: Bool
    let hasFigure: Bool
    let needsReview: Bool
    /// Bundle-relative figure paths, e.g. "圖/111110/1002_22.png".
    var figures: [String] = []
    /// The options are drawn inside the figure crop; answer buttons show letters only.
    var optionsAsImage = false
    /// Calculator rule of the source paper.
    var calculatorAllowed = false
    /// Syllabus unit ids ("視覺光學-1.4"); the first one is the primary unit.
    var concepts: [String] = []

    /// Primary syllabus unit, used by unit filters and per-unit counts.
    var primaryConcept: String? { concepts.first }

    static let letters = ["A", "B", "C", "D"]

    static func makeID(code: String, subject: String, number: Int) -> String {
        "\(code)_\(subject)_\(number)"
    }

    /// "115 年 一般 第 5 題"
    var sourceLabel: String { "\(year) 年 \(examKind) 第 \(number) 題" }

    /// True when any option text is missing or the stem refers to a figure we do not ship.
    var needsFigureNotice: Bool {
        guard figures.isEmpty else { return false }
        return hasFigure || Question.letters.contains { (options[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "115 年 一般"
    var paperLabel: String { "\(year) 年 \(examKind)" }

    /// Correction text for display, e.g. "答B或D或BD者均給分".
    var correctionSummary: String? {
        if allCredit { return "一律給分" }
        guard corrected else { return nil }
        if let note = correctionNote, !note.isEmpty {
            return note.replacingOccurrences(of: #"^第\s*\d+\s*題"#, with: "", options: .regularExpression)
        }
        return "答 " + answer.joined(separator: " 或 ") + " 者給分"
    }
}

enum Grading {
    /// Any letter in the corrected answer list counts as correct; all-credit questions are always correct.
    static func isCorrect(chosen: String, question: Question) -> Bool {
        question.allCredit || question.answer.contains(chosen)
    }
}
