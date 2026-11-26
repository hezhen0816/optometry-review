import Foundation
import Observation

// 學習版第二批: nightly weak-point analysis (GET /insights) and 檢討這回 (POST /review).
// Everything that touches the server's field names lives in this file, so a change on the server side is a
// one-file edit. Decoding is tolerant: missing or oddly typed fields never throw away the rest of a response.

// MARK: - Wire types

/// One 考點 note: what the learner probably mixes up and what to fix (AI generated).
struct InsightNote: Equatable, Codable {
    var misconception: String
    /// Inline Markdown, a few lines.
    var fix: String
    /// One line for the 今日 card.
    var reason: String
    /// Question ids the note cites (server format; not shown).
    var refs: [String]
    /// Per-question one-liners of a 檢討這回 answer, question id → text (optional in the response).
    var questionNotes: [String: String]
    /// When this note was produced; set by the client from the response's `generatedAt`.
    var at: Date?

    init(misconception: String = "", fix: String = "", reason: String = "", refs: [String] = [],
         questionNotes: [String: String] = [:], at: Date? = nil) {
        self.misconception = misconception
        self.fix = fix
        self.reason = reason
        self.refs = refs
        self.questionNotes = questionNotes
        self.at = at
    }

    private enum Keys: String, CodingKey { case misconception, fix, reason, refs, questions, questionNotes, at, generatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        misconception = Wire.string(c, .misconception)
        fix = Wire.string(c, .fix)
        reason = Wire.string(c, .reason)
        refs = Wire.strings(c, .refs)
        var notes: [String: String] = [:]
        if let map = try? c.decodeIfPresent([String: String].self, forKey: .questionNotes) { notes = map }
        // `questions: [{qid, note}]` as the review response may send it.
        if let list = try? c.decodeIfPresent([LossyQuestionNote].self, forKey: .questions) {
            for item in list { if let q = item.qid, let n = item.note, !n.isEmpty { notes[q] = n } }
        }
        questionNotes = notes
        at = Wire.date(c, .generatedAt) ?? Wire.date(c, .at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(misconception, forKey: .misconception)
        try c.encode(fix, forKey: .fix)
        try c.encode(reason, forKey: .reason)
        try c.encode(refs, forKey: .refs)
        try c.encode(questionNotes, forKey: .questionNotes)
        try c.encodeIfPresent(at.map { Wire.iso.string(from: $0) }, forKey: .at)
    }

    /// A note with nothing to show is dropped.
    var isEmpty: Bool { misconception.isEmpty && fix.isEmpty }

    private struct LossyQuestionNote: Decodable {
        let qid: String?
        let note: String?
        private enum Keys: String, CodingKey { case qid, note }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            qid = Wire.optionalString(c, .qid)
            note = Wire.optionalString(c, .note)
        }
    }
}

/// `GET /insights` → `{generatedAt, focus:[pointId], notes:{pointId:{misconception, fix, reason, refs}}}`.
struct InsightsSnapshot: Equatable, Codable {
    var generatedAt: Date?
    var focus: [String]
    var notes: [String: InsightNote]
    /// When the app downloaded it (used when the server sends no usable `generatedAt`).
    var fetchedAt: Date

    init(generatedAt: Date? = nil, focus: [String] = [], notes: [String: InsightNote] = [:], fetchedAt: Date = .now) {
        self.generatedAt = generatedAt
        self.focus = focus
        self.notes = notes
        self.fetchedAt = fetchedAt
    }

    private enum Keys: String, CodingKey { case generatedAt, focus, notes, fetchedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        generatedAt = Wire.date(c, .generatedAt)
        focus = Wire.strings(c, .focus)
        var map: [String: InsightNote] = [:]
        if let raw = try? c.decodeIfPresent([String: Lossy<InsightNote>].self, forKey: .notes) {
            for (id, item) in raw { if let note = item.value, !note.isEmpty { map[id] = note } }
        }
        let stamp = generatedAt
        notes = map.mapValues { var n = $0; if n.at == nil { n.at = stamp }; return n }
        fetchedAt = Wire.date(c, .fetchedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(generatedAt.map { Wire.iso.string(from: $0) }, forKey: .generatedAt)
        try c.encode(focus, forKey: .focus)
        try c.encode(notes, forKey: .notes)
        try c.encode(Wire.iso.string(from: fetchedAt), forKey: .fetchedAt)
    }

    /// The moment the analysis was made.
    var analyzedAt: Date { generatedAt ?? fetchedAt }

    static let freshness: TimeInterval = 36 * 3600

    /// 36 hours or younger (and not from the future by more than a day of clock skew).
    func isFresh(now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(analyzedAt)
        return age <= Self.freshness && age > -24 * 3600
    }
}

/// One question of a 檢討這回 group, as the server returns it.
struct ReviewQuestion: Equatable {
    let qid: String
    /// Original letter; "" for 「看解答」.
    let chosen: String
    let correct: Bool
    let unsure: Bool
    let answer: [String]
    /// One line about this question (「你選 C：…」); may be empty.
    let line: String
}

struct ReviewResultGroup: Equatable, Identifiable {
    let pointID: String
    let title: String
    /// nil: show the questions without the AI part.
    let note: InsightNote?
    let questions: [ReviewQuestion]
    var id: String { pointID }
}

/// `POST /review` response: `{generatedAt, groups:[{pointId, unit, title, note:{…}|null, questions:[{qid, chosen,
/// correct, unsure, answer:["B"], line}]}]}`; `{"groups":[]}` when nothing needs review.
struct ReviewResult: Equatable {
    var generatedAt: Date?
    var groups: [ReviewResultGroup]

    static func decode(_ data: Data) -> ReviewResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let generated = Wire.parseDate(root["generatedAt"])
        var groups: [ReviewResultGroup] = []
        for raw in root["groups"] as? [[String: Any]] ?? [] {
            guard let pid = raw["pointId"] as? String else { continue }
            var note: InsightNote?
            if let obj = raw["note"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: obj),
               var n = try? JSONDecoder().decode(InsightNote.self, from: d), !n.isEmpty {
                if n.at == nil { n.at = generated }
                note = n
            }
            let questions: [ReviewQuestion] = (raw["questions"] as? [[String: Any]] ?? []).compactMap { q in
                guard let qid = q["qid"] as? String else { return nil }
                let letters = (q["answer"] as? [String]) ?? (q["answer"] as? String).map { [$0] } ?? []
                return ReviewQuestion(qid: qid, chosen: q["chosen"] as? String ?? "", correct: q["correct"] as? Bool ?? false,
                                      unsure: q["unsure"] as? Bool ?? false, answer: letters,
                                      line: (q["line"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            groups.append(ReviewResultGroup(pointID: pid, title: raw["title"] as? String ?? "", note: note, questions: questions))
        }
        return ReviewResult(generatedAt: generated, groups: groups)
    }

    /// Notes of the groups, for the local 你的筆記.
    var notes: [String: InsightNote] {
        Dictionary(groups.compactMap { g in g.note.map { (g.pointID, $0) } }, uniquingKeysWith: { $1 })
    }
}

/// One answer of the round, as `POST /review` takes it.
struct RoundAnswer: Equatable {
    let qid: String
    /// Original option letter; "" for 「看解答」.
    let chosen: String
    let correct: Bool
    let unsure: Bool

    var jsonObject: [String: Any] { ["qid": qid, "chosen": chosen, "correct": correct, "unsure": unsure] }
}

// MARK: - Tolerant decoding helpers

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum Wire {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO 8601 (with or without fractions), a bare "yyyy-MM-dd HH:mm:ss", or epoch seconds / milliseconds.
    static func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            if let d = iso.date(from: s) ?? isoFraction.date(from: s) { return d }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Asia/Taipei")
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
                f.dateFormat = format
                if let d = f.date(from: s) { return d }
            }
            if let n = Double(s) { return epoch(n) }
            return nil
        }
        if let n = value as? Double { return epoch(n) }
        return nil
    }

    private static func epoch(_ n: Double) -> Date { Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }

    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return parseDate(s) }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return parseDate(n) }
        return nil
    }

    static func optionalString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        return nil
    }

    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String {
        (optionalString(c, key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strings, or numbers turned into strings; anything else gives an empty list.
    static func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        if let list = try? c.decodeIfPresent([String].self, forKey: key) { return list }
        if let list = try? c.decodeIfPresent([Int].self, forKey: key) { return list.map(String.init) }
        return []
    }
}

// MARK: - Client

enum WeakAnalysisError: Error, Equatable {
    case offline
    case budget
    case unavailable
    case badRequest
    case ai(AIError)

    var message: String {
        switch self {
        case .offline: "檢討這回需要網路，連上網路後再試"
        case .budget: "這個月的 AI 額度用完了，下個月再試"
        case .unavailable: "檢討服務暫時無法使用，稍後再試"
        case .badRequest: "這輪的作答無法送出檢討"
        case .ai(let e): e.message
        }
    }

    var retryable: Bool {
        switch self {
        case .offline, .unavailable: true
        case .budget, .badRequest: false
        case .ai(let e): e.retryable
        }
    }

    /// Non-200 answers of /review and /insights (body `{"error": "…"}`).
    static func map(status: Int, body: Data) -> WeakAnalysisError {
        let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        switch status {
        case 400: return .badRequest
        case 429: return text == "monthly budget reached" ? .budget : .ai(.rateLimited)
        case 503: return .unavailable
        case 502: return .ai(.generationFailed)
        default: return .ai(AIClient.map(status: status, body: body))
        }
    }
}

struct WeakAnalysisClient {
    static let reviewTimeout: TimeInterval = 100
    let config: AIConfig
    var session: URLSession = .shared
    var deviceID: String?
    var router: ServerRouter = .shared

    func insights() async throws -> InsightsSnapshot {
        let data = try await send(path: "insights", method: "GET", body: nil, timeout: 30)
        guard var snapshot = try? JSONDecoder().decode(InsightsSnapshot.self, from: data) else { throw WeakAnalysisError.ai(.server(200)) }
        snapshot.fetchedAt = .now
        return snapshot
    }

    func review(_ answers: [RoundAnswer]) async throws -> ReviewResult {
        let body = try JSONSerialization.data(withJSONObject: answers.map(\.jsonObject))
        let data = try await send(path: "review", method: "POST", body: body, timeout: Self.reviewTimeout)
        guard let result = ReviewResult.decode(data) else { throw WeakAnalysisError.ai(.generationFailed) }
        return result
    }

    /// `GET /insights/run`: whether 「現在分析」 is allowed right now.
    func manualStatus() async throws -> ManualAnalysisStatus {
        let (status, data) = try await transport(path: "insights/run", method: "GET", body: nil, timeout: 30)
        guard status == 200 else { throw WeakAnalysisError.map(status: status, body: data) }
        guard let parsed = ManualAnalysisStatus.decode(data) else { throw WeakAnalysisError.ai(.server(200)) }
        return parsed
    }

    /// Body of `POST /insights/run`: the point ids on the 今日 card (the server accepts at most 3).
    static func manualBody(points: [String]) -> Data {
        let body: [String: Any] = ["points": Array(points.prefix(3))]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `POST /insights/run`: analyses the given card points now. A refusal (409 with a reason code) comes back as the
    /// new status instead of an error, so the button can show why.
    func runManual(points: [String]) async throws -> ManualRunOutcome {
        let (status, data) = try await transport(path: "insights/run", method: "POST", body: Self.manualBody(points: points),
                                                 timeout: Self.reviewTimeout + 25)
        if status == 200 { return .done }
        if status == 409, let refused = ManualAnalysisStatus.decodeRefusal(data) { return .refused(refused) }
        throw WeakAnalysisError.map(status: status, body: data)
    }

    private func send(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        let (status, data) = try await transport(path: path, method: method, body: body, timeout: timeout)
        if status == 200 { return data }
        throw WeakAnalysisError.map(status: status, body: data)
    }

    private func transport(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> (Int, Data) {
        guard let token = config.token, !token.isEmpty else { throw WeakAnalysisError.ai(.notConfigured) }
        var req = router.makeRequest(path, config: config, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(deviceID ?? "unknown", forHTTPHeaderField: "X-Device-Id")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let data: Data
        let status: Int
        do {
            (data, status) = try await router.data(for: req, path: path, config: config, session: session)
        } catch {
            if error is CancellationError { throw error }
            if let e = error as? URLError {
                switch e.code {
                case .cancelled: throw CancellationError()
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: throw WeakAnalysisError.offline
                case .timedOut: throw WeakAnalysisError.ai(.timeout)
                default: throw WeakAnalysisError.ai(.unreachable)
                }
            }
            throw WeakAnalysisError.ai(.unreachable)
        }
        return (status, data)
    }
}

// MARK: - 現在分析 (manual nightly analysis)

/// `GET /insights/run` → `{allowed, reason, newAnswers, needed}`; reason is `already_today` or `not_enough_answers`.
struct ManualAnalysisStatus: Equatable {
    var allowed: Bool
    var reason: String?
    var newAnswers: Int
    var needed: Int

    static func decode(_ data: Data) -> ManualAnalysisStatus? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allowed = json["allowed"] as? Bool else { return nil }
        return ManualAnalysisStatus(allowed: allowed, reason: json["reason"] as? String,
                                    newAnswers: json["newAnswers"] as? Int ?? 0, needed: json["needed"] as? Int ?? 10)
    }

    /// The 409 body `{error: reason, newAnswers, needed}` of a refused run; nil for `busy` and unknown codes.
    static func decodeRefusal(_ data: Data) -> ManualAnalysisStatus? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = json["error"] as? String, ["already_today", "not_enough_answers"].contains(reason) else { return nil }
        return ManualAnalysisStatus(allowed: false, reason: reason, newAnswers: json["newAnswers"] as? Int ?? 0,
                                    needed: json["needed"] as? Int ?? 10)
    }

    /// Button text and whether it can be pressed; nil status hides the button.
    static func label(_ status: ManualAnalysisStatus?, running: Bool) -> (title: String, enabled: Bool)? {
        if running { return ("分析中", false) }
        guard let status else { return nil }
        if status.allowed { return ("現在分析", true) }
        switch status.reason {
        case "already_today": return ("今天已分析過", false)
        case "not_enough_answers": return ("再答 \(max(1, status.needed - status.newAnswers)) 題可分析", false)
        default: return ("暫時不能分析", false)
        }
    }
}

enum ManualRunOutcome: Equatable {
    case done
    case refused(ManualAnalysisStatus)
}

/// State of 今日「最該補的考點」's 「現在分析」 button. The server decides; this only mirrors its answer.
@MainActor
@Observable
final class ManualAnalysisStore {
    static let shared = ManualAnalysisStore()
    /// Status requests closer together than this are skipped (the server allows 60 an hour).
    static let minStatusInterval: TimeInterval = 20

    private(set) var status: ManualAnalysisStatus?
    private(set) var running = false
    /// Why the last run did not work, in words for the card.
    private(set) var failure: String?
    @ObservationIgnored private var lastStatusAt: Date?

    /// Same conditions as `InsightsStore.refreshIfNeeded`: a token, usage sharing on, not in tests.
    static func isAvailable(config: AIConfig = AIConfig.load(), defaults: UserDefaults = .standard) -> Bool {
        !UsageLog.runningTests && config.isConfigured
            && defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true
    }

    var label: (title: String, enabled: Bool)? {
        Self.isAvailable() ? ManualAnalysisStatus.label(status, running: running) : nil
    }

    func refreshStatus(config: AIConfig = AIConfig.load(), deviceID: String? = nil, now: Date = .now) async {
        guard Self.isAvailable(config: config), !running else { return }
        if let last = lastStatusAt, now.timeIntervalSince(last) < Self.minStatusInterval { return }
        lastStatusAt = now
        // Answers still waiting in the upload queue would otherwise not count.
        await UsageLog.shared.flush()
        let client = WeakAnalysisClient(config: config, deviceID: deviceID ?? UsageLog.shared.deviceID)
        if let latest = try? await client.manualStatus() { status = latest }
    }

    /// 「現在分析」: runs on the server, then downloads the new notes whatever the throttle says.
    func run(points: [String], config: AIConfig = AIConfig.load(), deviceID: String? = nil) async {
        guard Self.isAvailable(config: config), !running, status?.allowed == true else { return }
        running = true
        failure = nil
        defer { running = false }
        await UsageLog.shared.flush()
        let client = WeakAnalysisClient(config: config, deviceID: deviceID ?? UsageLog.shared.deviceID)
        do {
            switch try await client.runManual(points: points) {
            case .done:
                await InsightsStore.shared.refreshIfNeeded(config: config, deviceID: deviceID, force: true)
                lastStatusAt = nil
                if let latest = try? await client.manualStatus() { status = latest } else { status = nil }
                lastStatusAt = .now
            case .refused(let refused):
                status = refused
            }
        } catch let error as WeakAnalysisError {
            failure = Self.failureText(error)
        } catch {
            failure = WeakAnalysisError.ai(.unreachable).message
        }
    }

    static func failureText(_ error: WeakAnalysisError) -> String {
        error == .offline ? "分析需要網路，連上網路後再試" : error.message
    }
}

// MARK: - Store

/// Downloads and keeps the latest analysis on the device. Fetching is throttled (a few times a day).
@MainActor
@Observable
final class InsightsStore {
    static let shared = InsightsStore()
    static let snapshotKey = "insights.snapshot"
    static let fetchLogKey = "insights.fetchLog"
    /// At most this many requests per rolling 24 hours, and never closer together than `minInterval`.
    static let maxPerDay = 4
    static let minInterval: TimeInterval = 60 * 60

    private(set) var snapshot: InsightsSnapshot?
    /// Bumped on every change so views can react with `onChange`.
    private(set) var version = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var fetching = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.snapshotKey) {
            snapshot = try? JSONDecoder().decode(InsightsSnapshot.self, from: data)
        }
    }

    /// The analysis that may drive 今日: 36 hours or younger.
    func fresh(now: Date = .now) -> InsightsSnapshot? {
        guard let snapshot, snapshot.isFresh(now: now) else { return nil }
        return snapshot
    }

    func note(for pointID: String) -> InsightNote? {
        guard let n = snapshot?.notes[pointID], !n.isEmpty else { return nil }
        return n
    }

    func set(_ new: InsightsSnapshot?) {
        snapshot = new
        if let new, let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.snapshotKey) }
        else { defaults.removeObject(forKey: Self.snapshotKey) }
        version += 1
    }

    /// Adds the notes of a 檢討這回 result so the handout shows them straight away; focus and age stay as they were.
    func merge(_ result: ReviewResult) {
        let fresh = result.notes.filter { !$0.value.isEmpty }
        guard !fresh.isEmpty else { return }
        var s = snapshot ?? InsightsSnapshot(generatedAt: nil, focus: [], notes: [:], fetchedAt: Date(timeIntervalSince1970: 0))
        for (id, note) in fresh { s.notes[id] = note }
        set(s)
    }

    // MARK: Throttle

    func fetchLog(now: Date = .now) -> [Date] {
        let raw = defaults.array(forKey: Self.fetchLogKey) as? [Double] ?? []
        return raw.map { Date(timeIntervalSince1970: $0) }.filter { now.timeIntervalSince($0) < 24 * 3600 }
    }

    func canFetch(now: Date = .now) -> Bool {
        let log = fetchLog(now: now)
        if log.count >= Self.maxPerDay { return false }
        if let last = log.max(), now.timeIntervalSince(last) < Self.minInterval { return false }
        return true
    }

    private func recordFetch(now: Date) {
        let log = fetchLog(now: now) + [now]
        defaults.set(log.map(\.timeIntervalSince1970), forKey: Self.fetchLogKey)
    }

    /// Called at launch and when the app returns to the foreground. Does nothing without a token, with usage
    /// sharing switched off, in tests, or when throttled. Failures keep the old analysis.
    func refreshIfNeeded(config: AIConfig = AIConfig.load(), deviceID: String? = nil,
                         session: URLSession = .shared, now: Date = .now, force: Bool = false) async {
        guard !UsageLog.runningTests, config.isConfigured, !fetching,
              defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true, force || canFetch(now: now) else { return }
        fetching = true
        defer { fetching = false }
        recordFetch(now: now)
        let client = WeakAnalysisClient(config: config, session: session, deviceID: deviceID ?? UsageLog.shared.deviceID)
        guard let latest = try? await client.insights() else { return }
        // An empty answer (no analysis yet) does not erase a note the learner already has.
        if latest.notes.isEmpty && latest.focus.isEmpty && latest.generatedAt == nil { return }
        set(latest)
    }
}

// MARK: - Ordering of 最該補

/// A row of 今日「最該補的考點」: the point and, when an analysis drives the order, its one-line reason.
struct WeakPointEntry: Equatable {
    let stat: PointStat
    let reason: String?
}

enum WeakPointRanking {
    /// With an analysis ≤ 36 hours old: its focus order (points that are still 待加強／還不穩), each with its reason,
    /// then the rule ordering fills up to `limit` without reasons. Otherwise the batch-1 rule ordering alone.
    static func today(stats: [PointStat], snapshot: InsightsSnapshot?, limit: Int, now: Date = .now) -> [WeakPointEntry] {
        let rule = PointMastery.weakest(stats, limit: stats.count)
        guard let snapshot, snapshot.isFresh(now: now) else {
            return rule.prefix(limit).map { WeakPointEntry(stat: $0, reason: nil) }
        }
        let byID = Dictionary(uniqueKeysWithValues: stats.map { ($0.point.id, $0) })
        var result: [WeakPointEntry] = []
        var used = Set<String>()
        for id in snapshot.focus where result.count < limit && !used.contains(id) {
            guard let stat = byID[id], stat.label == .needsWork || stat.label == .shaky else { continue }
            used.insert(id)
            let reason = snapshot.notes[id]?.reason ?? ""
            result.append(WeakPointEntry(stat: stat, reason: reason.isEmpty ? nil : reason))
        }
        for stat in rule where result.count < limit && !used.contains(stat.point.id) {
            result.append(WeakPointEntry(stat: stat, reason: nil))
        }
        return result
    }
}

// MARK: - 檢討這回 grouping

/// One wrong or guessed question of the round, with where it belongs.
struct ReviewItem: Equatable, Identifiable {
    let answer: RoundAnswer
    var id: String { answer.qid }
}

struct ReviewGroup: Equatable, Identifiable {
    /// "" collects questions without a 考點 tag.
    let pointID: String
    let items: [ReviewItem]
    var id: String { pointID }
}

enum RoundReview {
    /// The first answer of every question in the round: that is what the learner actually believed.
    static func firstAnswers(_ log: [RoundAnswer]) -> [RoundAnswer] {
        var seen = Set<String>()
        return log.filter { seen.insert($0.qid).inserted }
    }

    /// Groups the server did not return (it explains at most three 考點), so 檢討這回 still lists every flagged question.
    static func notServed(_ groups: [ReviewGroup], servedPointIDs: Set<String>) -> [ReviewGroup] {
        groups.filter { !servedPointIDs.contains($0.pointID) }
    }

    /// Wrong or guessed answers.
    static func flagged(_ answers: [RoundAnswer]) -> [RoundAnswer] {
        answers.filter { !$0.correct || $0.unsure }
    }

    /// Groups flagged answers by 考點. A question with two tags goes to the one the analysis covers (when known),
    /// else its first tag. Biggest group first; ties keep the order of first appearance.
    static func group(_ flagged: [RoundAnswer], pointsOfQuestion: [String: [String]],
                      covered: Set<String> = []) -> [ReviewGroup] {
        var order: [String] = []
        var items: [String: [ReviewItem]] = [:]
        for a in flagged {
            let tags = pointsOfQuestion[a.qid] ?? []
            let pid = tags.first(where: covered.contains) ?? tags.first ?? ""
            if items[pid] == nil { order.append(pid) }
            items[pid, default: []].append(ReviewItem(answer: a))
        }
        let indexed = order.enumerated().sorted { a, b in
            let (ca, cb) = (items[a.element]!.count, items[b.element]!.count)
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }
        return indexed.map { ReviewGroup(pointID: $0.element, items: items[$0.element]!) }
    }
}

// MARK: - Option text of the 「你選了 X」 line

enum ChosenNoteText {
    /// Server letters are the ORIGINAL ones; the panel shows the order the learner saw. 〔X〕 markers and the leading
    /// 「你選了 X」 letter are rewritten to the shown letters.
    static func display(_ note: String, order: OptionOrder) -> String {
        var text = note
        if !order.isOriginal, let m = text.firstMatch(of: /^你選了\s*([A-D])/) {
            let shown = order.displayedLetter(forOriginal: String(m.1))
            text = "你選了 \(shown)" + text[m.range.upperBound...]
        }
        let mapped = AIOptionMarkers.map(text, order: order)
        // 「你選了〔C〕」 turns into 「你選了C」; keep the same spacing as the plain form.
        if let m = mapped.firstMatch(of: /^你選了\s*([A-D])/) { return "你選了 \(m.1)" + mapped[m.range.upperBound...] }
        return mapped
    }
}
