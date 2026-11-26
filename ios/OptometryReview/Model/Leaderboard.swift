import Foundation
import Observation

// 讀書夥伴 (formerly the weekly leaderboard) served by server/app.py (/leaderboard/*). Scores come from uploaded `answer` usage events,
// so the board lags until the usage queue has been sent.

struct LeaderboardWeek: Codable, Equatable {
    /// Monday and Sunday (inclusive), Taipei dates as "2026-10-05".
    let start: String
    let end: String

    /// 「10/5 – 10/11」
    var label: String { "\(Self.monthDay(start)) – \(Self.monthDay(end))" }

    static func monthDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return iso }
        return "\(parts[1])/\(parts[2])"
    }

    /// Index of `now` in the week (0 = Monday), or nil outside it. Uses Taipei dates like the server.
    func dayIndex(of now: Date) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let c = cal.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let s = f.date(from: start), let t = f.date(from: today),
              let d = cal.dateComponents([.day], from: s, to: t).day, (0..<7).contains(d) else { return nil }
        return d
    }
}

struct LeaderboardEntry: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let rank: Int
    let correct: Int
    let days: Int
    /// 0–1, nil before any answer this week.
    let accuracy: Double?
    let me: Bool
    /// Correct answers per day Mon–Sun; nil from servers that predate it (then fetched per member).
    var daily: [Int]? = nil
}

struct LeaderboardBoard: Decodable, Equatable {
    let joined: Bool
    let week: LeaderboardWeek?
    let entries: [LeaderboardEntry]
    /// My correct answers last week; nil when there was no activity (or an older server that does not send it).
    let lastWeekCorrect: Int?

    private enum CodingKeys: String, CodingKey { case joined, week, entries, me }
    private struct MeInfo: Decodable { let lastWeekCorrect: Int? }

    init(joined: Bool, week: LeaderboardWeek?, entries: [LeaderboardEntry], lastWeekCorrect: Int? = nil) {
        self.joined = joined
        self.week = week
        self.entries = entries
        self.lastWeekCorrect = lastWeekCorrect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        joined = try c.decode(Bool.self, forKey: .joined)
        week = try c.decodeIfPresent(LeaderboardWeek.self, forKey: .week)
        entries = try c.decodeIfPresent([LeaderboardEntry].self, forKey: .entries) ?? []
        lastWeekCorrect = try? c.decodeIfPresent(MeInfo.self, forKey: .me)?.lastWeekCorrect
    }

    var mine: LeaderboardEntry? { entries.first(where: \.me) }

    /// Cards in display order: me first, then the others by name (the server's rank is ignored).
    var ordered: [LeaderboardEntry] { LeaderboardText.ordered(entries) }
}

struct LeaderboardMember: Decodable, Equatable {
    let name: String
    let correct: Int
    let days: Int
    /// Correct answers Monday…Sunday.
    let daily: [Int]
    let subjects: [String: Int]
}

struct LeaderboardProfile: Decodable, Equatable {
    let id: String
    let name: String
    let joined: Bool
}

enum LeaderboardError: Error, Equatable {
    case notConfigured
    case unreachable
    case unauthorized
    case blocked
    case invalidName
    case notFound
    case rateLimited
    case server(Int)

    var message: String {
        switch self {
        case .notConfigured: "讀書夥伴目前無法使用"
        case .unreachable: "目前連不到伺服器，請稍後再試"
        case .unauthorized: "讀書夥伴設定有誤"
        case .blocked: "這台裝置目前無法使用讀書夥伴"
        case .invalidName: "顯示名稱需為 1–12 個字"
        case .notFound: "找不到這位參加者，可能已退出讀書夥伴"
        case .rateLimited: "太頻繁了，稍後再試"
        case .server(let code): "伺服器發生錯誤（\(code)），稍後再試"
        }
    }
}

/// Display helpers shared by the board, the member page and the 成績 row.
enum LeaderboardText {
    static let maxNameLength = 12

    /// 「68%」; short of every answer correct shows at most 99, like the rest of the app.
    static func accuracy(_ value: Double?) -> String {
        guard let value else { return "—" }
        let p = Int((value * 100).rounded())
        return "\(value < 1 ? min(99, p) : p)%"
    }

    /// Me first, then the others by name (id breaks ties). No ranking.
    static func ordered(_ entries: [LeaderboardEntry]) -> [LeaderboardEntry] {
        entries.sorted { a, b in
            if a.me != b.me { return a.me }
            return a.name == b.name ? a.id < b.id : a.name < b.name
        }
    }

    /// 「比上週多 12 題」「比上週少 3 題」「和上週一樣」; nil when last week is unknown.
    static func weekOverWeek(this: Int, last: Int?) -> String? {
        guard let last else { return nil }
        if this > last { return "比上週多 \(this - last) 題" }
        if this < last { return "比上週少 \(last - this) 題" }
        return "和上週一樣"
    }

    /// 「正確率 68%」, only on my own card: other people's accuracy is never shown, whatever the server sends.
    static func ownAccuracyLine(_ entry: LeaderboardEntry) -> String? {
        guard entry.me, entry.accuracy != nil else { return nil }
        return "正確率 \(accuracy(entry.accuracy))"
    }

    /// 「3F2A」 from the device id: only a server-side fallback; the UI asks the user for a name.
    static func defaultName(deviceID: String?) -> String {
        String((deviceID ?? "").replacingOccurrences(of: "-", with: "").prefix(4)).uppercased()
    }

    /// Trimmed name the server accepts (1–12 characters, no control or format characters), or nil.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxNameLength).contains(name.count) else { return nil }
        let bad = CharacterSet.controlCharacters.union(.illegalCharacters)
        guard name.unicodeScalars.allSatisfy({ !bad.contains($0) && $0.properties.generalCategory != .format }) else {
            return nil
        }
        return name
    }
}

protocol LeaderboardService {
    func board() async throws -> LeaderboardBoard
    func setProfile(name: String, joined: Bool) async throws -> LeaderboardProfile
    func member(id: String) async throws -> LeaderboardMember
}

/// HTTP client with the AI client's auth headers (Bearer app token + X-Device-Id).
struct LeaderboardClient: LeaderboardService {
    typealias Transport = (URLRequest) async throws -> (Data, Int)

    let config: AIConfig
    let deviceID: String
    var router: ServerRouter = .shared
    var transport: Transport = LeaderboardClient.urlSession

    init(config: AIConfig, deviceID: String, router: ServerRouter = .shared,
         transport: @escaping Transport = LeaderboardClient.urlSession) {
        self.config = config
        self.deviceID = deviceID
        self.router = router
        self.transport = transport
    }

    init(baseURL: URL, token: String, deviceID: String,
         fallbackBaseURLs: [URL] = AIConfig.defaultFallbackBaseURLs, router: ServerRouter = .shared,
         transport: @escaping Transport = LeaderboardClient.urlSession) {
        self.init(config: AIConfig(baseURL: baseURL, token: token, fallbackBaseURLs: fallbackBaseURLs),
                  deviceID: deviceID, router: router, transport: transport)
    }

    static func urlSession(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct ProfileBody: Encodable {
        let name: String
        let joined: Bool
    }

    func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = router.makeRequest(path, config: config, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(config.token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    func board() async throws -> LeaderboardBoard {
        try decode(await send(path: "leaderboard"))
    }

    func setProfile(name: String, joined: Bool) async throws -> LeaderboardProfile {
        let body = try JSONEncoder().encode(ProfileBody(name: name, joined: joined))
        return try decode(await send(path: "leaderboard/profile", method: "POST", body: body))
    }

    func member(id: String) async throws -> LeaderboardMember {
        guard id.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil else { throw LeaderboardError.notFound }
        return try decode(await send(path: "leaderboard/member/\(id)"))
    }

    private func send(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let request = makeRequest(path, method: method, body: body)
        let data: Data, status: Int
        do {
            (data, status) = try await router.send(request, path: path, config: config, transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LeaderboardError.unreachable
        }
        if status == 200 { return data }
        throw Self.map(status: status)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw LeaderboardError.server(200) }
    }

    static func map(status: Int) -> LeaderboardError {
        switch status {
        case 400: .invalidName
        case 401: .unauthorized
        case 403: .blocked
        case 404: .notFound
        case 429: .rateLimited
        case 502, 503, 504: .unreachable
        default: .server(status)
        }
    }
}

/// Settings keys and the live board state shared by 成績, the board, and 設定.
@MainActor @Observable
final class LeaderboardModel {
    static let joinedKey = "leaderboard.joined"
    static let nameKey = "leaderboard.name"
    /// The first-open 「加入讀書夥伴」 sheet was answered (加入 or 先不要).
    static let promptedKey = "leaderboard.prompted"
    /// Left locally but the server has not confirmed yet; retried until it does.
    static let pendingLeaveKey = "leaderboard.pendingLeave"

    static let shared = LeaderboardModel()

    private let defaults: UserDefaults
    private let makeService: @MainActor () -> LeaderboardService?
    private(set) var board: LeaderboardBoard?
    private(set) var error: LeaderboardError?
    private(set) var loading = false
    /// Monday…Sunday correct answers per entry id, for the card bar strips (filled by `loadDailies`).
    private(set) var dailies: [String: [Int]] = [:]

    init(defaults: UserDefaults = .standard,
         service: (@MainActor () -> LeaderboardService?)? = nil) {
        self.defaults = defaults
        makeService = service ?? { LeaderboardModel.liveService() }
    }

    /// Nil without an app token, or in the simulator without a `-usageBaseURL` test server.
    static func liveService() -> LeaderboardService? {
        guard let config = UsageLog.shared.serverConfig,
              let device = UsageLog.shared.deviceID else { return nil }
        return LeaderboardClient(config: config, deviceID: device)
    }

    var usageEnabled: Bool { defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true }
    var joined: Bool { defaults.bool(forKey: Self.joinedKey) }
    var prompted: Bool { defaults.bool(forKey: Self.promptedKey) }
    var pendingLeave: Bool { defaults.bool(forKey: Self.pendingLeaveKey) }
    var isActive: Bool { usageEnabled && joined }

    var name: String {
        defaults.string(forKey: Self.nameKey) ?? LeaderboardText.defaultName(deviceID: UsageLog.shared.deviceID)
    }

    /// The name the user chose, or empty before they ever joined (the join sheet starts blank).
    var savedName: String { defaults.string(forKey: Self.nameKey) ?? "" }

    func markPrompted() { defaults.set(true, forKey: Self.promptedKey) }

    /// Sends pending answers first so this week's count is as fresh as possible.
    /// The local choice is re-checked after every await: a leave (or 使用紀錄回傳 off) during the request wins.
    func refresh(flushFirst: Bool = true) async {
        await retryPendingLeave()
        guard isActive else { board = nil; return }
        guard let service = makeService() else { error = .notConfigured; return }
        loading = true
        defer { loading = false }
        if flushFirst { await UsageLog.shared.flush() }
        do {
            guard isActive else { board = nil; return }
            var b = try await service.board()
            guard isActive else { board = nil; return }
            if !b.joined {
                // The server lost the profile (e.g. reset): join again with the remembered name, only while the
                // local choice is still 參加.
                _ = try await service.setProfile(name: name, joined: true)
                guard isActive else {
                    // Left meanwhile: undo the re-join.
                    defaults.set(true, forKey: Self.pendingLeaveKey)
                    await retryPendingLeave()
                    board = nil
                    return
                }
                b = try await service.board()
                guard isActive else { board = nil; return }
            }
            board = b
            error = nil
        } catch let e as LeaderboardError {
            error = e
        } catch {}
    }

    /// Fetches each card's 7-day counts (one member request per entry; failures leave that strip empty).
    func loadDailies() async {
        guard isActive, let service = makeService(), let entries = board?.entries else { return }
        var result: [String: [Int]] = [:]
        for e in entries { if let d = e.daily { result[e.id] = d } }
        let missing = entries.filter { $0.daily == nil }
        await withTaskGroup(of: (String, [Int]?).self) { group in
            for e in missing {
                group.addTask { (e.id, try? await service.member(id: e.id).daily) }
            }
            for await (id, daily) in group { if let daily { result[id] = daily } }
        }
        guard isActive else { return }
        dailies = dailies.merging(result) { _, new in new }
    }

    /// Re-sends an unconfirmed leave. Safe to call any time (app foreground, 成績, 設定).
    func retryPendingLeave() async {
        guard pendingLeave, !joined, let service = makeService() else { return }
        do {
            _ = try await service.setProfile(name: name, joined: false)
            if !joined { defaults.set(false, forKey: Self.pendingLeaveKey) }
        } catch {}
    }

    /// Joins (or renames while joined). Throws so the caller can keep its sheet open with the message.
    func join(name raw: String) async throws {
        guard let name = LeaderboardText.validName(raw) else { throw LeaderboardError.invalidName }
        guard let service = makeService() else { throw LeaderboardError.notConfigured }
        _ = try await service.setProfile(name: name, joined: true)
        defaults.set(name, forKey: Self.nameKey)
        defaults.set(true, forKey: Self.joinedKey)
        defaults.set(false, forKey: Self.pendingLeaveKey)
        markPrompted()
        await refresh(flushFirst: false)
    }

    /// Leaves the board. The local choice changes at once; until the server confirms, the leave stays pending and
    /// is retried by `retryPendingLeave` (so others stop seeing this device as soon as it gets through).
    func leave() async throws {
        defaults.set(false, forKey: Self.joinedKey)
        defaults.set(true, forKey: Self.pendingLeaveKey)
        board = nil
        dailies = [:]
        guard let service = makeService() else { return }
        _ = try await service.setProfile(name: name, joined: false)
        if !joined { defaults.set(false, forKey: Self.pendingLeaveKey) }
    }

    func member(id: String) async throws -> LeaderboardMember {
        guard let service = makeService() else { throw LeaderboardError.notConfigured }
        return try await service.member(id: id)
    }
}
