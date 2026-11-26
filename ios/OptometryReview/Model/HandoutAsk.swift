import Foundation
import Observation

// 問講義: questions about one handout (pointId nil) or one 考點, answered by `POST /handout/ask`.
// Conversations live in a local JSON file per (unit, point). They are not study data: no AttemptRecord, no iCloud,
// not part of the review pool, stats, mastery or 讀書夥伴.

enum HandoutAskRules {
    /// One round = her question plus the answer.
    static let maxRounds = 5
    /// The server accepts at most 10 history items.
    static let maxHistory = 10
    static let minQuestion = 1
    static let maxQuestion = 500

    /// The question as it will be sent (trimmed); nil when empty. Longer text is cut to the limit.
    static func normalized(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= minQuestion else { return nil }
        return String(t.prefix(maxQuestion))
    }

    static func rounds(_ turns: [AIChatTurn]) -> Int { turns.filter { $0.role == .user }.count }

    static func isFull(_ turns: [AIChatTurn]) -> Bool { rounds(turns) >= maxRounds }

    /// Conversation key: "<unit>" for the whole handout, "<unit>#<point>" for a 考點.
    static func key(unit: String, pointID: String?) -> String {
        guard let pointID, !pointID.isEmpty else { return unit }
        return "\(unit)#\(pointID)"
    }
}

/// Request body. `pointId` is always present (JSON null for the whole handout).
struct HandoutAskBody: Encodable {
    let unit: String
    let pointId: String?
    let question: String
    let history: [AIChatTurn]

    private enum Keys: String, CodingKey { case unit, pointId, question, history }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(unit, forKey: .unit)
        if let pointId { try c.encode(pointId, forKey: .pointId) } else { try c.encodeNil(forKey: .pointId) }
        try c.encode(question, forKey: .question)
        try c.encode(history, forKey: .history)
    }
}

struct HandoutAskResponse: Decodable, Equatable {
    let unit: String?
    let pointId: String?
    let text: String?
}

extension AIClient {
    /// `history` is the conversation so far; only the last ten items are sent, each cut to the server's 2000-character limit.
    func handoutAsk(unit: String, pointID: String?, question: String, history: [AIChatTurn]) async throws -> String {
        guard let q = HandoutAskRules.normalized(question) else { throw AIError.questionRejected }
        let body = HandoutAskBody(unit: unit, pointId: pointID, question: q,
                                  history: history.suffix(HandoutAskRules.maxHistory).map(\.forSending))
        let data = try await post("handout/ask", body, mapStatus: { Self.mapHandoutAsk(status: $0, body: $1) })
        guard let r = try? JSONDecoder().decode(HandoutAskResponse.self, from: data),
              let text = r.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.generationFailed
        }
        return text
    }

    /// Followup mapping, except the statuses that mean something else for this endpoint.
    static func mapHandoutAsk(status: Int, body: Data) -> AIError {
        switch status {
        case 400: return .questionRejected
        case 404: return .handoutUnavailable
        case 503:
            // A 503 without the server's JSON body comes from a reverse proxy: the server is down.
            return map(status: status, body: body) == .unreachable ? .unreachable : .bankUnavailable
        default: return map(status: status, body: body)
        }
    }
}

/// Conversations by key, kept in one JSON file (Application Support, not iCloud).
struct HandoutAskStore {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("handout-ask.json")
    }

    init(url: URL = HandoutAskStore.defaultURL) { self.url = url }

    func loadAll() -> [String: [AIChatTurn]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [AIChatTurn]].self, from: data)) ?? [:]
    }

    func turns(for key: String) -> [AIChatTurn] { loadAll()[key] ?? [] }

    func save(_ turns: [AIChatTurn], for key: String) {
        var all = loadAll()
        all[key] = turns.isEmpty ? nil : turns
        write(all)
    }

    func clearAll() { try? FileManager.default.removeItem(at: url) }

    private func write(_ all: [String: [AIChatTurn]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// App-wide owner of 問講義 requests, like `AIExplainer`: leaving the screen does not drop an answer that arrives later.
@MainActor
@Observable
final class HandoutAsker {
    static var shared: HandoutAsker?

    private(set) var conversations: [String: [AIChatTurn]] = [:]
    /// Question waiting for an answer, per conversation key.
    private(set) var pending: [String: String] = [:]
    /// Last failure and the question that failed (so the field can be refilled).
    private(set) var failure: [String: (error: AIError, question: String)] = [:]

    let config: AIConfig
    @ObservationIgnored private let client: AIClient
    @ObservationIgnored private let store: HandoutAskStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    var isConfigured: Bool { config.isConfigured }

    init(config: AIConfig, store: HandoutAskStore = HandoutAskStore(), session: URLSession = .shared, deviceID: String? = nil) {
        self.config = config
        self.store = store
        self.client = AIClient(config: config, session: session, deviceID: deviceID ?? UsageLog.shared.deviceID)
        self.conversations = store.loadAll()
    }

    func turns(_ key: String) -> [AIChatTurn] { conversations[key] ?? [] }

    func reloadFromDisk() { conversations = store.loadAll() }

    /// Sends one question. Returns the task so tests can await it.
    @discardableResult
    func ask(unit: String, pointID: String?, question: String) -> Task<Void, Never> {
        let key = HandoutAskRules.key(unit: unit, pointID: pointID)
        let history = turns(key)
        guard let q = HandoutAskRules.normalized(question), tasks[key] == nil, !HandoutAskRules.isFull(history) else { return Task {} }
        guard isConfigured else {
            failure[key] = (.notConfigured, q)
            return Task {}
        }
        pending[key] = q
        failure[key] = nil
        let client = self.client
        let task = Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await client.handoutAsk(unit: unit, pointID: pointID, question: q, history: history))
            } catch {
                outcome = .failure(error)
            }
            // 「重新開始」 already cleaned up this conversation.
            if Task.isCancelled { return }
            switch outcome {
            case .success(let answer): self?.append(q, answer, key: key)
            case .failure(let error) where error is CancellationError: break
            case .failure(let error): self?.failure[key] = (error as? AIError ?? .unreachable, q)
            }
            self?.pending[key] = nil
            self?.tasks[key] = nil
        }
        tasks[key] = task
        return task
    }

    private func append(_ question: String, _ answer: String, key: String) {
        var turns = conversations[key] ?? []
        turns += [AIChatTurn(role: .user, text: question), AIChatTurn(role: .assistant, text: answer)]
        conversations[key] = turns
        store.save(turns, for: key)
    }

    func dismissFailure(_ key: String) { failure[key] = nil }

    /// 「重新開始」: forgets this conversation (a request still in flight is dropped).
    func startOver(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
        pending[key] = nil
        failure[key] = nil
        conversations[key] = nil
        store.save([], for: key)
    }

    func clearAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        pending = [:]
        failure = [:]
        conversations = [:]
        store.clearAll()
    }
}
