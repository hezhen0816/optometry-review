import Foundation
import SwiftData
import Observation

/// App-wide owner of AI requests. Requests are not tied to a screen: leaving a question only stops the UI from
/// waiting, and a response that arrives later is still written to the on-device cache. Only 「取消」 cancels.
@MainActor
@Observable
final class AIExplainer {
    /// Set once at launch (OptometryReviewApp). Views read it directly so sheets and covers need no environment wiring.
    static var shared: AIExplainer?

    enum Phase: Equatable {
        case idle
        case loading(regenerate: Bool, since: Date)
        case failed(AIError, regenerate: Bool)
    }

    enum FeedbackPhase: Equatable {
        case idle, sending, sent
        case failed(AIError)
    }

    let config: AIConfig
    @ObservationIgnored private let client: AIClient
    @ObservationIgnored private let cache: AICacheStore

    private(set) var phase: [String: Phase] = [:]
    /// Follow-up question waiting for an answer, per question.
    private(set) var pendingQuestion: [String: String] = [:]
    /// Last follow-up failure and the question that failed (so the field can be refilled).
    private(set) var followupFailure: [String: (error: AIError, question: String)] = [:]
    private(set) var feedback: [String: FeedbackPhase] = [:]
    /// 「你選了 X：…」 lines by "<question id>|<original letter>"; kept on the device (the explanation cache stays as is).
    private(set) var chosenNotes: [String: String] = [:]
    @ObservationIgnored private var noteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let chosenNotesKey = "ai.chosenNotes"
    static let chosenNotesLimit = 300

    @ObservationIgnored private var explainTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var explainTokens: [String: UUID] = [:]
    @ObservationIgnored private var followupTasks: [String: Task<Void, Never>] = [:]

    var isConfigured: Bool { config.isConfigured }

    init(config: AIConfig, context: ModelContext, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.chosenNotes = defaults.dictionary(forKey: Self.chosenNotesKey) as? [String: String] ?? [:]
        self.config = config
        self.client = AIClient(config: config, session: session, deviceID: UsageLog.shared.deviceID)
        self.cache = AICacheStore(context: context)
    }

    func phase(for id: String) -> Phase { phase[id] ?? .idle }

    static func noteKey(_ localID: String, _ chosen: String) -> String { "\(localID)|\(chosen)" }

    func chosenNote(for localID: String, chosen: String?) -> String? {
        chosen.flatMap { chosenNotes[Self.noteKey(localID, $0)] }
    }

    private func storeChosenNote(_ note: String?, localID: String, chosen: String?) {
        guard let note, let chosen, !note.isEmpty else { return }
        chosenNotes[Self.noteKey(localID, chosen)] = note
        if chosenNotes.count > Self.chosenNotesLimit {
            for key in chosenNotes.keys.sorted().prefix(chosenNotes.count - Self.chosenNotesLimit) { chosenNotes[key] = nil }
        }
        defaults.set(chosenNotes, forKey: Self.chosenNotesKey)
    }

    /// The explanation is already on the device but the 「你選了 X」 line is not: asks the server for it quietly
    /// (no loading state on the panel; the line appears when it arrives).
    @discardableResult
    func loadChosenNote(_ p: AIQuestionPayload, chosen: String) -> Task<Void, Never> {
        let key = Self.noteKey(p.localID, chosen)
        if let running = noteTasks[key] { return running }
        guard isConfigured, chosenNotes[key] == nil else { return Task {} }
        let client = self.client
        let task = Task { [weak self] in
            if let result = try? await client.explain(p, regenerate: false, chosen: chosen) {
                self?.storeChosenNote(result.chosenNote, localID: p.localID, chosen: chosen)
            }
            self?.noteTasks[key] = nil
        }
        noteTasks[key] = task
        return task
    }

    func isLoading(_ id: String) -> Bool {
        if case .loading = phase(for: id) { return true }
        return false
    }

    /// Starts (or joins) an explanation request. Returns the task so tests can await it.
    @discardableResult
    func explain(_ p: AIQuestionPayload, regenerate: Bool = false, chosen: String? = nil) -> Task<Void, Never> {
        if regenerate { UsageLog.shared.log("ai", ["action": "regenerate", "qid": p.localID]) }
        if let running = explainTasks[p.localID] { return running }
        guard isConfigured else {
            phase[p.localID] = .failed(.notConfigured, regenerate: regenerate)
            return Task {}
        }
        phase[p.localID] = .loading(regenerate: regenerate, since: .now)
        let client = self.client
        let token = UUID()
        explainTokens[p.localID] = token
        let task = Task { [weak self] in
            let outcome: Result<AIExplainResult, Error>
            do {
                outcome = .success(try await client.explain(p, regenerate: regenerate, chosen: chosen))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            // A response always reaches the cache, even when the screen is gone or 「取消」 came too late.
            if case .success(let result) = outcome {
                self.cache.save(result, for: p.localID)
                self.storeChosenNote(result.chosenNote, localID: p.localID, chosen: chosen)
                self.feedback[p.localID] = nil
            }
            // A newer request for the same question owns the phase from here on.
            guard self.explainTokens[p.localID] == token else { return }
            switch outcome {
            case .success: self.phase[p.localID] = .idle
            case .failure(let error) where error is CancellationError: self.phase[p.localID] = .idle
            case .failure(let error): self.phase[p.localID] = .failed(error as? AIError ?? .unreachable, regenerate: regenerate)
            }
            self.explainTasks[p.localID] = nil
            self.explainTokens[p.localID] = nil
        }
        explainTasks[p.localID] = task
        return task
    }

    /// 「取消」: stops the request. The server may still finish and keep its own copy.
    func cancel(_ localID: String) {
        explainTasks[localID]?.cancel()
        explainTasks[localID] = nil
        explainTokens[localID] = nil
        phase[localID] = .idle
    }

    func clearError(_ localID: String) {
        if case .failed = phase(for: localID) { phase[localID] = .idle }
    }

    @discardableResult
    func ask(_ p: AIQuestionPayload, question: String, order: OptionOrder = .original) -> Task<Void, Never> {
        let q = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AIClient.maxQuestionLength))
        guard !q.isEmpty, followupTasks[p.localID] == nil else { return Task {} }
        UsageLog.shared.log("ai", ["action": "followup", "qid": p.localID])
        let history = cache.explanation(for: p.localID)?.followups ?? []
        pendingQuestion[p.localID] = q
        followupFailure[p.localID] = nil
        let client = self.client
        let task = Task { [weak self] in
            do {
                let answer = try await client.followup(p, question: q, history: history, order: order)
                self?.cache.appendFollowup(question: q, answer: answer, for: p.localID)
            } catch is CancellationError {
            } catch {
                self?.followupFailure[p.localID] = (error as? AIError ?? .unreachable, q)
            }
            self?.pendingQuestion[p.localID] = nil
            self?.followupTasks[p.localID] = nil
        }
        followupTasks[p.localID] = task
        return task
    }

    func dismissFollowupFailure(_ localID: String) {
        followupFailure[localID] = nil
    }

    @discardableResult
    func reportWrong(_ p: AIQuestionPayload, note: String?) -> Task<Void, Never> {
        UsageLog.shared.log("ai", ["action": "flag", "qid": p.localID])
        feedback[p.localID] = .sending
        let client = self.client
        return Task { [weak self] in
            do {
                try await client.feedbackWrong(p, note: note)
                self?.cache.markReported(p.localID)
                self?.feedback[p.localID] = .sent
            } catch {
                self?.feedback[p.localID] = .failed(error as? AIError ?? .unreachable)
            }
        }
    }
}
