import Foundation

/// AI-generated calculation questions (題庫/AI模擬/ai_questions.json, format in docs/AI出題與圖解.md 4.2).
/// They live beside the official bank, never inside it: no QuestionRecord, no review card, no exam use.
enum AIQID {
    static let prefix = "ai:"
    /// `AttemptRecord.source` of an AI answer.
    static let source = "ai"
    static func isAI(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

/// One figure parameter: a number (D, mm, cm, degrees) or a word (OD, up, MR …).
enum AIParam: Decodable, Hashable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .text(try c.decode(String.self)) }
    }
}

/// `figure` of a question: a figure type and its parameters.
struct AIFigureSpec: Decodable, Hashable {
    let type: String
    let params: [String: AIParam]

    init(type: String, params: [String: AIParam]) {
        self.type = type
        self.params = params
    }

    func number(_ key: String) -> Double? {
        if case .number(let v)? = params[key] { return v }
        return nil
    }

    func text(_ key: String) -> String? {
        if case .text(let v)? = params[key] { return v }
        return nil
    }
}

struct AIAudit: Decodable, Hashable {
    let model: String?
    let agreed: Bool?
    let at: String?
}

struct AIQuestion: Identifiable, Decodable, Hashable {
    let id: String
    let templateId: String
    let subject: String
    let unitID: String
    let pointIDs: [String]
    let stem: String
    let options: [String: String]
    let answer: String
    let wrongNotes: [String: String]
    let steps: [String]
    let figure: AIFigureSpec?
    /// Official question id (same as the bank's key) the template comes from.
    let sourceQuestionID: String?
    let audit: AIAudit?

    private enum Keys: String, CodingKey {
        case id, templateId, subject, unitID, pointIDs, stem, options, answer, wrongNotes, steps, figure, sourceQuestionID, audit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        templateId = try c.decodeIfPresent(String.self, forKey: .templateId) ?? ""
        subject = try c.decode(String.self, forKey: .subject)
        unitID = try c.decode(String.self, forKey: .unitID)
        pointIDs = try c.decodeIfPresent([String].self, forKey: .pointIDs) ?? []
        stem = try c.decode(String.self, forKey: .stem)
        options = try c.decode([String: String].self, forKey: .options)
        answer = try c.decode(String.self, forKey: .answer)
        wrongNotes = try c.decodeIfPresent([String: String].self, forKey: .wrongNotes) ?? [:]
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        figure = try c.decodeIfPresent(AIFigureSpec.self, forKey: .figure)
        sourceQuestionID = try c.decodeIfPresent(String.self, forKey: .sourceQuestionID)
        audit = try c.decodeIfPresent(AIAudit.self, forKey: .audit)
    }

    init(id: String, templateId: String = "t", subject: String = "視覺光學", unitID: String, pointIDs: [String] = [],
         stem: String = "?", options: [String: String] = ["A": "1", "B": "2", "C": "3", "D": "4"], answer: String = "A",
         wrongNotes: [String: String] = [:], steps: [String] = [], figure: AIFigureSpec? = nil,
         sourceQuestionID: String? = nil) {
        self.id = id
        self.templateId = templateId
        self.subject = subject
        self.unitID = unitID
        self.pointIDs = pointIDs
        self.stem = stem
        self.options = options
        self.answer = answer
        self.wrongNotes = wrongNotes
        self.steps = steps
        self.figure = figure
        self.sourceQuestionID = sourceQuestionID
        self.audit = nil
    }

    var answerText: String { options[answer] ?? "" }

    func isCorrect(_ letter: String) -> Bool { letter == answer }
}

/// The bundled AI questions, indexed by unit, point and subject.
struct AIQuestionBank {
    let questions: [AIQuestion]
    let byID: [String: AIQuestion]
    let byUnit: [String: [AIQuestion]]
    let byPoint: [String: [AIQuestion]]
    /// The file is a hand-made sample for the UI, not the generator's output.
    let isSample: Bool

    static let empty = AIQuestionBank(questions: [], isSample: false)

    init(questions: [AIQuestion], isSample: Bool) {
        self.questions = questions
        self.isSample = isSample
        byID = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byUnit = Dictionary(grouping: questions, by: \.unitID)
        var points: [String: [AIQuestion]] = [:]
        for q in questions { for p in q.pointIDs { points[p, default: []].append(q) } }
        byPoint = points
    }

    private struct File: Decodable {
        let sample: Bool?
        let questions: [AIQuestion]
    }

    /// Questions with an unusable shape (missing answer option, not the id prefix) are dropped.
    init(json: Data) {
        let file = try? JSONDecoder().decode(File.self, from: json)
        let usable = (file?.questions ?? []).filter { q in
            AIQID.isAI(q.id) && q.options[q.answer] != nil && q.options.count >= 2
        }
        self.init(questions: usable, isSample: file?.sample ?? false)
    }

    static func load(_ bundle: Bundle) -> AIQuestionBank {
        guard let url = bundle.url(forResource: "ai_questions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return AIQuestionBank(json: data)
    }

    func questions(unit: String) -> [AIQuestion] { byUnit[unit] ?? [] }
    func questions(point: String) -> [AIQuestion] { byPoint[point] ?? [] }
    func questions(subject: String) -> [AIQuestion] { questions.filter { $0.subject == subject } }
}
