import Foundation

private struct PaperFile: Decodable {
    struct RawQuestion: Decodable {
        let number: Int
        let stem: String
        let options: [String: String]
        let answer: [String]
        let originalAnswer: String?
        let corrected: Bool?
        let correctionNote: String?
        let allCredit: Bool?
        let hasFigure: Bool?
        let needsReview: Bool?
        let figures: [String]?
        let optionsAsImage: Bool?
        let concepts: [String]?
    }

    let code: String
    let year: Int
    let examKind: String
    let session_note: String?
    let cls: String?
    let subject: String
    let paperCode: String?
    let calculatorAllowed: Bool?
    let questions: [RawQuestion]
}

/// One exam paper (one subject of one exam session).
struct Paper: Identifiable, Hashable {
    /// "<code>_<subject>"
    var id: String { Paper.makeID(code: code, subject: subject) }
    let code: String
    let year: Int
    let examKind: String
    /// e.g. "花東考區補辦"
    let sessionNote: String?
    let subject: String
    /// Subject file prefix, e.g. "0902" (from "0902_視覺光學.json").
    let fileCode: String
    /// Official paper code printed on the paper, e.g. "3109".
    let paperCode: String?
    let calculatorAllowed: Bool
    let questionIDs: [String]
    /// Some question has a corrected answer or all-credit.
    let hasCorrectedQuestions: Bool

    static func makeID(code: String, subject: String) -> String { "\(code)_\(subject)" }

    /// "115 年 一般"
    var label: String { "\(year) 年 \(examKind)" }

    /// Bundle-relative PDF path, e.g. "原始/115_115100/0903_視光學_更正答案.pdf".
    func pdfPath(_ kind: PaperDocument) -> String {
        "\(QuestionBank.pdfFolderName)/\(year)_\(code)/\(fileCode)_\(subject)_\(kind.rawValue).pdf"
    }
}

enum PaperDocument: String, CaseIterable, Identifiable {
    case questions = "試題"
    case answers = "答案"
    case corrected = "更正答案"
    var id: String { rawValue }
}

/// Read-only question bank loaded from the bundled "轉檔" folder.
final class QuestionBank {
    static let folderName = "轉檔"
    static let pdfFolderName = "原始"

    let questions: [Question]
    let byID: [String: Question]
    let papers: [Paper]
    let paperByID: [String: Paper]
    /// Syllabus units per subject, in syllabus order.
    let unitsBySubject: [String: [ConceptUnit]]
    let unitByID: [String: ConceptUnit]
    /// Root URL of bundled resources; nil for in-memory banks (tests, previews).
    let resourceRoot: URL?
    /// 考點 and 重點講義 (empty for in-memory banks).
    let learning: LearningContent
    /// AI-generated calculation questions (kept apart from the official bank).
    let ai: AIQuestionBank

    init(questions: [Question], papers: [Paper] = [], units: [ConceptUnit]? = nil, resourceRoot: URL? = nil,
         learning: LearningContent = .empty, ai: AIQuestionBank = .empty) {
        self.questions = questions
        var map: [String: Question] = [:]
        for q in questions { map[q.id] = q }
        byID = map
        self.papers = papers
        var pmap: [String: Paper] = [:]
        for p in papers { pmap[p.id] = p }
        paperByID = pmap
        // Without a unit table (tests, previews) the units are derived from the questions, named by id.
        let list = units ?? ConceptUnit.derived(from: questions)
        unitsBySubject = Dictionary(grouping: list, by: \.subject)
        unitByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.resourceRoot = resourceRoot
        self.learning = learning
        self.ai = ai
    }

    /// Loads every paper JSON under the bundled folder. Only 驗光師 papers are kept.
    static func loadFromBundle(_ bundle: Bundle = .main) -> QuestionBank {
        guard let root = bundle.url(forResource: folderName, withExtension: nil) else {
            assertionFailure("Question bank folder missing from bundle")
            return QuestionBank(questions: [])
        }
        let fm = FileManager.default
        var urls: [URL] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "json" { urls.append(url) }
        }
        urls.sort { $0.path < $1.path }
        let decoder = JSONDecoder()
        var all: [Question] = []
        var papers: [Paper] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let paper = try? decoder.decode(PaperFile.self, from: data) else { continue }
            // 驗光生 and papers without a class field never enter the bank.
            guard isOptometristPaper(cls: paper.cls) else { continue }
            let calc = paper.calculatorAllowed ?? false
            var ids: [String] = []
            var corrected = false
            for r in paper.questions {
                let id = Question.makeID(code: paper.code, subject: paper.subject, number: r.number)
                ids.append(id)
                if (r.corrected ?? false) || (r.allCredit ?? false) { corrected = true }
                all.append(Question(
                    id: id,
                    code: paper.code, year: paper.year, examKind: paper.examKind, subject: paper.subject,
                    number: r.number, stem: r.stem, options: r.options, answer: r.answer,
                    originalAnswer: r.originalAnswer, corrected: r.corrected ?? false,
                    correctionNote: r.correctionNote, allCredit: r.allCredit ?? false,
                    hasFigure: r.hasFigure ?? false, needsReview: r.needsReview ?? false,
                    figures: (r.figures ?? []).map(bundlePath(forFigure:)),
                    optionsAsImage: r.optionsAsImage ?? false,
                    calculatorAllowed: calc, concepts: r.concepts ?? []))
            }
            let fileCode = url.deletingPathExtension().lastPathComponent.components(separatedBy: "_").first ?? ""
            papers.append(Paper(code: paper.code, year: paper.year, examKind: paper.examKind,
                                sessionNote: paper.session_note, subject: paper.subject, fileCode: fileCode,
                                paperCode: paper.paperCode, calculatorAllowed: calc, questionIDs: ids,
                                hasCorrectedQuestions: corrected))
        }
        return QuestionBank(questions: all, papers: papers, units: ConceptUnit.loadTable(bundle),
                            resourceRoot: bundle.resourceURL, learning: LearningContent.load(bundle, papers: papers),
                            ai: AIQuestionBank.load(bundle))
    }

    /// Only 專技高考「驗光師」 papers enter the bank; 驗光生 and papers missing the class field are skipped.
    static func isOptometristPaper(cls: String?) -> Bool { cls == "驗光師" }

    /// "題庫/圖/111110/1002_22.png" → "圖/111110/1002_22.png"
    static func bundlePath(forFigure path: String) -> String {
        path.hasPrefix("題庫/") ? String(path.dropFirst("題庫/".count)) : path
    }

    /// Questions eligible for daily review. 特考 papers only when the setting is on.
    func reviewPool(includeSpecial: Bool) -> [Question] {
        questions.filter { $0.examKind == ExamKind.general || (includeSpecial && $0.examKind == ExamKind.special) }
    }

    func units(of subject: String) -> [ConceptUnit] { unitsBySubject[subject] ?? [] }

    func questions(of paper: Paper) -> [Question] {
        paper.questionIDs.compactMap { byID[$0] }
    }

    func paper(for question: Question) -> Paper? {
        paperByID[Paper.makeID(code: question.code, subject: question.subject)]
    }

    /// URL of a bundled resource path, or nil when missing.
    func resourceURL(_ path: String) -> URL? {
        guard let root = resourceRoot else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func pdfURL(_ paper: Paper, _ kind: PaperDocument) -> URL? {
        resourceURL(paper.pdfPath(kind))
    }

    /// The paper has a corrected-answer PDF or a corrected question.
    func hasCorrection(_ paper: Paper) -> Bool {
        paper.hasCorrectedQuestions || pdfURL(paper, .corrected) != nil
    }
}
