import Foundation
import SwiftData

/// Where the AI server lives and how to authenticate. Public builds default to offline use.
struct AIConfig: Equatable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8070")!
    static let defaultFallbackBaseURLs: [URL] = []

    var baseURL: URL
    var token: String?
    var fallbackBaseURLs: [URL] = AIConfig.defaultFallbackBaseURLs

    var isConfigured: Bool { !(token ?? "").isEmpty }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     arguments: [String] = ProcessInfo.processInfo.arguments) -> AIConfig {
        let baseURL = environment["OPTO_AI_BASE_URL"].flatMap(validBaseURL)
        let token = baseURL == nil ? nil : environment["OPTO_AI_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = AIConfig(baseURL: baseURL ?? defaultBaseURL, token: token)
        if baseURL != nil, let fallbacks = environment["OPTO_AI_FALLBACK_URLS"] {
            config.fallbackBaseURLs = fallbacks.split(separator: ",").compactMap {
                validBaseURL($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        #if DEBUG
        if let i = arguments.firstIndex(of: "-aiBaseURL"), i + 1 < arguments.count, let u = validBaseURL(arguments[i + 1]) {
            config.baseURL = u
            // A local primary must never silently fall back to a configured fallback.
            config.fallbackBaseURLs = []
        }
        if let i = arguments.firstIndex(of: "-aiFallbackURL"), i + 1 < arguments.count,
           let u = validBaseURL(arguments[i + 1]) { config.fallbackBaseURLs = [u] }
        // Lets simulator walkthroughs show the screens that need an AI key; pair it with -aiBaseURL.
        if let i = arguments.firstIndex(of: "-aiToken"), i + 1 < arguments.count { config.token = arguments[i + 1] }
        #endif
        return config
    }

    private static func validBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme), url.host != nil else { return nil }
        return url
    }
}

/// Server-side question id: "<code>_<subject file code>_<number>", e.g. "115100_0902_5".
enum AIQuestionID {
    static func make(code: String, fileCode: String, number: Int) -> String { "\(code)_\(fileCode)_\(number)" }

    static func make(_ q: Question, bank: QuestionBank) -> String? {
        guard let paper = bank.paper(for: q) else { return nil }
        return make(code: q.code, fileCode: paper.fileCode, number: q.number)
    }
}

/// Question fields sent to the server (always in ORIGINAL option order and letters).
struct AIQuestionContext: Codable, Equatable {
    var subject: String
    var stem: String
    var options: [String: String]
    var answer: [String]
    var correctionNote: String?
    var allCredit: Bool

    init(subject: String, stem: String, options: [String: String], answer: [String], correctionNote: String?, allCredit: Bool) {
        self.subject = subject
        self.stem = stem
        self.options = options
        self.answer = answer
        self.correctionNote = correctionNote
        self.allCredit = allCredit
    }

    /// Clamped to the server's field limits so a long field never turns into a 400.
    init(_ q: Question) {
        subject = String(q.subject.prefix(100))
        stem = String(q.stem.prefix(2000))
        var opts: [String: String] = [:]
        for l in Question.letters { opts[l] = String((q.options[l] ?? "").prefix(500)) }
        options = opts
        answer = q.answer.filter { Question.letters.contains($0) }
        correctionNote = q.correctionNote.map { String($0.prefix(500)) }
        allCredit = q.allCredit
    }
}

/// Everything needed to ask about one question.
struct AIQuestionPayload: Equatable {
    /// Local key (Question.id) used by the on-device cache.
    let localID: String
    /// Server id ("115100_0902_5").
    let serverID: String
    let context: AIQuestionContext
}

/// One message of the follow-up thread.
struct AIChatTurn: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String

    /// The server rejects history items over 2000 characters (Python `len`, i.e. Unicode scalars).
    static let maxSentText = 2000

    /// This turn as sent in `history`: text cut to the server limit.
    var forSending: AIChatTurn {
        guard text.unicodeScalars.count > Self.maxSentText else { return self }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(Self.maxSentText))
        return AIChatTurn(role: role, text: String(scalars))
    }
}

struct AIExplainResult: Equatable {
    let text: String
    let version: Int
    let createdAt: String
    let cached: Bool
    /// 「你選了 X：…」, only when the request carried the learner's wrong choice.
    var chosenNote: String? = nil
}

/// Failures with the copy shown in the panel.
enum AIError: Error, Equatable {
    case notConfigured
    case unreachable
    case timeout
    case unauthorized
    case blocked
    case deviceLimit
    case rateLimited
    case busy
    case generationFailed
    case inconsistent
    case badRequest
    /// 問講義: the server has no such unit or point (404), or its question bank is not loaded (503 with a JSON body).
    case handoutUnavailable
    case bankUnavailable
    /// 問講義: the server refused the question text itself (400).
    case questionRejected
    case server(Int)

    var message: String {
        switch self {
        case .notConfigured: "AI 解析未設定"
        case .unreachable: "目前連不到解析服務，請稍後再試"
        case .timeout: "等太久沒有回應，稍後再試"
        case .unauthorized: "AI 解析設定有誤"
        case .blocked: "AI 解析目前無法使用"
        case .deviceLimit: "今天的 AI 解析次數已用完，明天再試"
        case .rateLimited: "次數已達上限，稍後再試"
        case .busy: "正在處理別的題目，稍等一下再試"
        case .generationFailed: "這次解析沒有產生出來，稍後再試"
        case .inconsistent: "AI 解析與官方答案不一致，已略過"
        case .badRequest: "這題的資料無法送出解析"
        case .handoutUnavailable: "這份講義還不能提問，稍後再試"
        case .bankUnavailable: "講義題庫暫時無法使用，稍後再試"
        case .questionRejected: "這個問題無法送出，請換個說法再試"
        case .server(let code): "伺服器發生錯誤（\(code)），稍後再試"
        }
    }

    /// Whether a 「再試一次」 button makes sense.
    var retryable: Bool {
        switch self {
        case .notConfigured, .unauthorized, .blocked, .deviceLimit, .badRequest, .rateLimited, .questionRejected: false
        default: true
        }
    }
}

/// Thin HTTP client for server/app.py. All calls throw `AIError` (or `CancellationError`).
struct AIClient {
    static let timeout: TimeInterval = 150
    static let maxHistory = 6
    static let maxQuestionLength = 500
    static let maxNoteLength = 300

    let config: AIConfig
    var session: URLSession = .shared
    var deviceID: String?
    var router: ServerRouter = .shared

    private struct ExplainBody: Encodable {
        let id: String
        let subject: String
        let stem: String
        let options: [String: String]
        let answer: [String]
        let correctionNote: String?
        let allCredit: Bool
        let regenerate: Bool
        /// ORIGINAL letter of the learner's wrong choice; omitted otherwise.
        let chosen: String?
    }

    private struct ExplainResponse: Decodable {
        let id: String?
        let text: String?
        let cached: Bool?
        let version: Int?
        let createdAt: String?
        let error: String?
        let chosenNote: String?
    }

    private struct FollowupBody: Encodable {
        let id: String
        let question: String
        let history: [AIChatTurn]
        let context: AIQuestionContext
        /// Original letter at each on-screen position ("CADB"); the server maps the student's letters with it.
        let displayOrder: String
    }

    private struct FollowupResponse: Decodable {
        let text: String?
    }

    private struct FeedbackBody: Encodable {
        let id: String
        let kind: String
        let note: String?
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    func explain(_ p: AIQuestionPayload, regenerate: Bool, chosen: String? = nil) async throws -> AIExplainResult {
        let c = p.context
        let body = ExplainBody(id: p.serverID, subject: c.subject, stem: c.stem, options: c.options, answer: c.answer,
                               correctionNote: c.correctionNote, allCredit: c.allCredit, regenerate: regenerate,
                               chosen: chosen.flatMap { Question.letters.contains($0) ? $0 : nil })
        let data = try await post("explain", body)
        guard let r = try? JSONDecoder().decode(ExplainResponse.self, from: data) else { throw AIError.server(200) }
        if r.error == "inconsistent" { throw AIError.inconsistent }
        guard let text = r.text, !text.isEmpty else { throw AIError.generationFailed }
        let note = r.chosenNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIExplainResult(text: text, version: r.version ?? 0, createdAt: r.createdAt ?? "", cached: r.cached ?? false,
                               chosenNote: (note?.isEmpty ?? true) ? nil : note)
    }

    /// `history` is trimmed to the last six messages (server limit) and sent as received (raw 〔X〕 markers).
    /// `order` is the on-screen option order, sent as `displayOrder`.
    func followup(_ p: AIQuestionPayload, question: String, history: [AIChatTurn],
                  order: OptionOrder = .original) async throws -> String {
        let body = FollowupBody(id: p.serverID, question: String(question.prefix(Self.maxQuestionLength)),
                                history: history.suffix(Self.maxHistory).map(\.forSending), context: p.context,
                                displayOrder: order.displayOrderString)
        let data = try await post("followup", body)
        guard let r = try? JSONDecoder().decode(FollowupResponse.self, from: data), let text = r.text, !text.isEmpty else {
            throw AIError.generationFailed
        }
        return text
    }

    func feedbackWrong(_ p: AIQuestionPayload, note: String?) async throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = FeedbackBody(id: p.serverID, kind: "wrong",
                                note: (trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(Self.maxNoteLength)))
        _ = try await post("feedback", body)
    }

    func makeRequest(_ path: String, body: some Encodable) throws -> URLRequest {
        guard let token = config.token, !token.isEmpty else { throw AIError.notConfigured }
        var req = router.makeRequest(path, config: config, timeoutInterval: Self.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(deviceID ?? "unknown", forHTTPHeaderField: "X-Device-Id")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    func post(_ path: String, _ body: some Encodable,
              mapStatus: (Int, Data) -> AIError = { AIClient.map(status: $0, body: $1) }) async throws -> Data {
        var req = try makeRequest(path, body: body)
        if deviceID == nil {
            let identity = await MainActor.run { UsageLog.shared.deviceID ?? "unknown" }
            req.setValue(identity, forHTTPHeaderField: "X-Device-Id")
        }
        let data: Data
        let status: Int
        do {
            (data, status) = try await router.data(for: req, path: path, config: config, session: session)
        } catch {
            throw Self.map(error)
        }
        if status == 200 { return data }
        throw mapStatus(status, data)
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return CancellationError()
            case .timedOut: return AIError.timeout
            default: return AIError.unreachable
            }
        }
        return AIError.unreachable
    }

    /// Non-200 responses. A 502/504 without the server's JSON body comes from a reverse proxy: the server is down.
    static func map(status: Int, body: Data) -> AIError {
        let serverError = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        switch status {
        case 401: return .unauthorized
        case 403: return serverError == "blocked" ? .blocked : .server(status)
        case 429: return serverError == "device limit" ? .deviceLimit : .rateLimited
        case 503: return serverError == nil ? .unreachable : .busy
        case 502: return serverError == "generation failed" ? .generationFailed : .unreachable
        case 504: return .unreachable
        case 400: return .badRequest
        default: return .server(status)
        }
    }
}

/// On-device cache of one question's explanation and follow-up thread. Keyed by `Question.id`.
extension SchemaV4 {
@Model
final class AIExplanation {
    var questionID: String = ""
    var text: String = ""
    var version: Int = 0
    /// Server timestamp (ISO 8601 string as sent).
    var createdAt: String = ""
    var savedAt: Date = Date(timeIntervalSince1970: 0)
    /// JSON-encoded `[AIChatTurn]`.
    var followupData: Data = Data("[]".utf8)
    /// 「解析有誤」 was sent for this version.
    var reportedWrong: Bool = false

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
typealias AIExplanation = SchemaV4.AIExplanation

/// SwiftData operations for `AIExplanation`.
struct AICacheStore {
    let context: ModelContext

    func explanation(for questionID: String) -> AIExplanation? {
        let d = FetchDescriptor<AIExplanation>(predicate: #Predicate { $0.questionID == questionID })
        return (try? context.fetch(d))?.sorted(by: StudyDeduplication.explanationOrder).first
    }

    /// Stores a new explanation. A different version (regenerate) replaces the text and starts a fresh thread.
    @discardableResult
    func save(_ r: AIExplainResult, for questionID: String, now: Date = .now) -> AIExplanation {
        if let existing = explanation(for: questionID) {
            if existing.text != r.text || existing.version != r.version {
                existing.text = r.text
                existing.version = r.version
                existing.createdAt = r.createdAt
                existing.followups = []
                existing.reportedWrong = false
            }
            existing.savedAt = now.wholeMillisecond
            try? context.save()
            return existing
        }
        let e = AIExplanation(questionID: questionID, text: r.text, version: r.version, createdAt: r.createdAt, now: now.wholeMillisecond)
        context.insert(e)
        try? context.save()
        return e
    }

    func appendFollowup(question: String, answer: String, for questionID: String) {
        guard let e = explanation(for: questionID) else { return }
        e.followups += [AIChatTurn(role: .user, text: question), AIChatTurn(role: .assistant, text: answer)]
        try? context.save()
    }

    func markReported(_ questionID: String) {
        guard let e = explanation(for: questionID) else { return }
        e.reportedWrong = true
        try? context.save()
    }

    func deleteAll() {
        try? context.delete(model: AIExplanation.self)
        try? context.save()
    }
}
