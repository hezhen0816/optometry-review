import Foundation

/// One 考點 (study point) of a syllabus unit, from 題庫/考點.json. Ids look like "視覺光學-1.4#2".
struct StudyPoint: Identifiable, Hashable {
    let id: String
    let unitID: String
    /// 1-based position inside the unit (the number after "#").
    let number: Int
    let title: String
    let summary: String
}

/// A rich-text block of a handout (題庫/講義.json). Text may hold `**bold**`, newlines and 「106111 #2」 question refs.
enum HandoutBlock: Decodable, Equatable {
    case paragraph(String)
    case list(ordered: Bool, items: [HandoutItem])
    case table(header: [String], rows: [[String]])
    case quote([String])
    case heading(String)
    /// A block type this app version does not know; skipped when drawing.
    case unknown

    private enum Keys: String, CodingKey { case type, text, items, header, rows, lines }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "p": self = .paragraph(try c.decode(String.self, forKey: .text))
        case "ul": self = .list(ordered: false, items: try c.decode([HandoutItem].self, forKey: .items))
        case "ol": self = .list(ordered: true, items: try c.decode([HandoutItem].self, forKey: .items))
        case "table":
            self = .table(header: try c.decode([String].self, forKey: .header), rows: try c.decode([[String]].self, forKey: .rows))
        case "quote": self = .quote(try c.decode([String].self, forKey: .lines))
        case "h3": self = .heading(try c.decode(String.self, forKey: .text))
        default: self = .unknown
        }
    }
}

struct HandoutItem: Decodable, Equatable {
    let text: String
    let children: [HandoutItem]?

    private enum Keys: String, CodingKey { case text, children }

    /// Children are plain strings in 講義.json; objects with their own `text` are accepted too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decode(String.self, forKey: .text)
        if let strings = try? c.decodeIfPresent([String].self, forKey: .children) {
            children = strings.map { HandoutItem(text: $0, children: nil) }
        } else {
            children = try c.decodeIfPresent([HandoutItem].self, forKey: .children)
        }
    }

    init(text: String, children: [HandoutItem]?) {
        self.text = text
        self.children = children
    }
}

struct HandoutPoint: Decodable, Equatable {
    let id: String
    let heading: String
    let blocks: [HandoutBlock]
}

struct HandoutSection: Decodable, Equatable {
    let heading: String
    let blocks: [HandoutBlock]
}

/// One self-quiz line: the question and the answer shown on demand.
struct QuizItem: Equatable {
    let question: String
    let answer: String
}

/// The 重點講義 of one unit (AI generated; the official answers stay the reference).
struct Handout: Decodable, Equatable {
    let unit: String
    let title: String
    let intro: [HandoutBlock]
    let points: [HandoutPoint]
    let extras: [HandoutSection]
    let quiz: [HandoutBlock]
    /// "106111 #2" → app question id.
    let refs: [String: String]

    /// 「問題 → 答案」 lines of the quiz; the trailing 「下一步」 paragraph is not a quiz line.
    var quizItems: [QuizItem] {
        var result: [QuizItem] = []
        for case .list(_, let items) in quiz {
            for item in items {
                let parts = item.text.components(separatedBy: "→")
                let q = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let a = parts.dropFirst().joined(separator: "→").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(QuizItem(question: q, answer: a))
            }
        }
        return result
    }
}

/// Study points, their questions and the handouts, loaded next to the question bank.
struct LearningContent {
    /// Points of each unit in handout order.
    let pointsByUnit: [String: [StudyPoint]]
    let pointByID: [String: StudyPoint]
    /// Question id → ids of the points it is tagged with (one or two).
    let pointsOfQuestion: [String: [String]]
    /// Point id → ids of the questions tagged with it.
    let questionsOfPoint: [String: [String]]
    let handouts: [String: Handout]

    static let empty = LearningContent(pointsByUnit: [:], pointByID: [:], pointsOfQuestion: [:],
                                       questionsOfPoint: [:], handouts: [:])

    private struct PointsFile: Decodable {
        struct Entry: Decodable { let id: String; let title: String; let summary: String }
        let units: [String: [Entry]]
        let tags: [String: [String]]
    }

    private struct HandoutsFile: Decodable { let handouts: [Handout] }

    var pointCount: Int { pointByID.count }

    func points(of unitID: String) -> [StudyPoint] { pointsByUnit[unitID] ?? [] }

    /// - Parameters:
    ///   - papers: map the tag key "<code>/<fileCode>/<number>" to question ids.
    init(pointsJSON: Data?, handoutsJSON: Data?, papers: [Paper]) {
        var byUnit: [String: [StudyPoint]] = [:]
        var byID: [String: StudyPoint] = [:]
        var ofQuestion: [String: [String]] = [:]
        var ofPoint: [String: [String]] = [:]
        if let pointsJSON, let file = try? JSONDecoder().decode(PointsFile.self, from: pointsJSON) {
            for (unit, entries) in file.units {
                byUnit[unit] = entries.map { e in
                    let number = Int(e.id.split(separator: "#").last ?? "") ?? 0
                    return StudyPoint(id: e.id, unitID: unit, number: number, title: e.title, summary: e.summary)
                }.sorted { $0.number < $1.number }
            }
            for list in byUnit.values { for p in list { byID[p.id] = p } }
            var subjectOf: [String: String] = [:]
            for p in papers { subjectOf["\(p.code)/\(p.fileCode)"] = p.subject }
            for key in file.tags.keys.sorted() {
                let parts = key.split(separator: "/").map(String.init)
                guard parts.count == 3, let n = Int(parts[2]), let subject = subjectOf["\(parts[0])/\(parts[1])"] else { continue }
                let qid = Question.makeID(code: parts[0], subject: subject, number: n)
                let ids = (file.tags[key] ?? []).filter { byID[$0] != nil }
                guard !ids.isEmpty else { continue }
                ofQuestion[qid] = ids
                for id in ids { ofPoint[id, default: []].append(qid) }
            }
        }
        var handouts: [String: Handout] = [:]
        if let handoutsJSON, let file = try? JSONDecoder().decode(HandoutsFile.self, from: handoutsJSON) {
            for h in file.handouts { handouts[h.unit] = h }
        }
        self.init(pointsByUnit: byUnit, pointByID: byID, pointsOfQuestion: ofQuestion,
                  questionsOfPoint: ofPoint, handouts: handouts)
    }

    init(pointsByUnit: [String: [StudyPoint]], pointByID: [String: StudyPoint], pointsOfQuestion: [String: [String]],
         questionsOfPoint: [String: [String]], handouts: [String: Handout]) {
        self.pointsByUnit = pointsByUnit
        self.pointByID = pointByID
        self.pointsOfQuestion = pointsOfQuestion
        self.questionsOfPoint = questionsOfPoint
        self.handouts = handouts
    }

    static func load(_ bundle: Bundle, papers: [Paper]) -> LearningContent {
        func data(_ name: String) -> Data? {
            bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        }
        return LearningContent(pointsJSON: data("考點"), handoutsJSON: data("講義"), papers: papers)
    }
}

/// Splits handout text into plain text and the question refs ("106111 #2") it mentions.
enum HandoutRefs {
    static let pattern = #"\d{6} #\d+"#
    private static let refList = "\(pattern)(?:[、,，\\s]+\(pattern))*"

    static func all(in text: String) -> [String] {
        text.matches(of: try! Regex(pattern)).map { String(text[$0.range]) }
    }

    /// Refs that stand at the end of the text, either 「…。（A #1、B #2）」 or a bare 「代表題：A #1、B #2」,
    /// are drawn as separate 44 pt buttons; the rest stays inline.
    static func splitTrailing(_ text: String) -> (body: String, refs: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parenthetical = "[（(]\\s*(\(refList))\\s*[）)]\\s*[。.]?$"
        let bare = "^(?:[^\\n]{0,8}[：:]\\s*)?(\(refList))$"
        for p in [parenthetical, bare] {
            guard let range = trimmed.range(of: p, options: .regularExpression) else { continue }
            let tail = String(trimmed[range])
            let refs = all(in: tail)
            guard !refs.isEmpty else { continue }
            var body = String(trimmed[trimmed.startIndex..<range.lowerBound])
            if p == bare, let first = trimmed.firstMatch(of: try! Regex(pattern)) {
                // Keep the label ("代表題：") as the body.
                body = String(trimmed[trimmed.startIndex..<first.range.lowerBound])
            }
            return (body.trimmingCharacters(in: .whitespaces), refs)
        }
        return (trimmed, [])
    }
}
