import Foundation

/// Accumulates active intervals only; repeated pause/resume callbacks are harmless.
struct UsageForegroundClock {
    private var started: Date?
    private(set) var seconds: TimeInterval = 0

    mutating func resume(at now: Date) {
        if started == nil { started = now }
    }

    mutating func pause(at now: Date) {
        if let started { seconds += max(0, now.timeIntervalSince(started)) }
        started = nil
    }

    mutating func take(at now: Date) -> TimeInterval {
        pause(at: now)
        let result = seconds
        seconds = 0
        return result
    }
}

struct UsageStateGate<Value: Equatable> {
    private var last: Value?

    mutating func reset() { last = nil }

    mutating func accepts(_ value: Value) -> Bool {
        guard last != value else { return false }
        last = value
        return true
    }
}

struct TodayUsageStatus: Equatable {
    let day: Date
    let dueCount: Int
    let retryCount: Int
    let newQuota: Int
    let correctToday: Int
    let dailyGoal: Int
    let examDaysLeft: Int?
    let reviewOnly: Bool

    @MainActor
    init(summary: TodaySummary, defaults: UserDefaults = .standard, now: Date = .now) {
        day = Calendar.current.startOfDay(for: now)
        dueCount = summary.reviewOnlyDueCount
        retryCount = summary.retryCount
        let mode = NewRatioMode.value(defaults)
        dailyGoal = SettingsKey.sanitizedDailyGoal(defaults.object(forKey: SettingsKey.dailyGoal))
        newQuota = DailyPlanner.newQuota(goal: dailyGoal, mode: mode, customPercent: NewRatioMode.customPercent(defaults))
        correctToday = summary.correctToday
        let examDate = defaults.double(forKey: SettingsKey.examDate)
        examDaysLeft = examDate > 0 ? DateText.daysBetween(now, Date(timeIntervalSince1970: examDate)) : nil
        reviewOnly = mode == .reviewOnly
    }

    var fields: [String: Any] {
        ["day": UsageLog.timestamp(day), "dueCount": dueCount, "retryCount": retryCount, "newQuota": newQuota,
         "correctToday": correctToday, "dailyGoal": dailyGoal, "examDaysLeft": examDaysLeft.map { $0 as Any } ?? NSNull(),
         "reviewOnly": reviewOnly]
    }
}

struct UsageNavigation {
    var previousUsed = false
    var nextUsed = false

    var fields: [String: Any] { ["previousUsed": previousUsed, "nextUsed": nextUsed] }
}

struct AIReadingUsage {
    let qid: String
    let trigger: String
    let cached: Bool
    var clock = UsageForegroundClock()
    private(set) var maxScrollDepth: Double = 0
    var otherOptions = false
    var handout = false
    var regenerated = false
    var followupAsked = false

    mutating func saw(depth: Double) {
        guard depth.isFinite else { return }
        maxScrollDepth = max(maxScrollDepth, min(1, max(0, depth)))
    }

    mutating func finish(at now: Date) -> [String: Any] {
        ["action": "reading", "qid": qid, "trigger": trigger, "cached": cached,
         "seconds": clock.take(at: now), "maxScrollDepth": maxScrollDepth, "otherOptions": otherOptions,
         "handout": handout, "regenerated": regenerated, "followupAsked": followupAsked]
    }
}

/// A logical open survives replacement of the panel when switching between narrow and wide layouts.
@MainActor
final class AIUsageSession {
    var value: AIReadingUsage?
    private var owners: [UUID: Bool] = [:]
    private let now: () -> Date
    private let sink: UsageLog.Sink

    init(now: @escaping () -> Date = { .now }, sink: UsageLog.Sink? = nil) {
        self.now = now
        self.sink = sink ?? { UsageLog.shared.log($0, $1) }
    }

    func attach(_ owner: UUID, qid: String, trigger: String, cached: Bool) {
        owners[owner] = false
        if value == nil {
            value = AIReadingUsage(qid: qid, trigger: trigger, cached: cached)
            sink("ai", ["action": "explain", "qid": qid, "trigger": trigger, "cached": cached])
        }
    }

    func update(_ owner: UUID, visible: Bool, depth: Double? = nil) {
        guard owners[owner] != nil else { return }
        owners[owner] = visible
        if visible, let depth { value?.saw(depth: depth) }
        if owners.values.contains(true) { value?.clock.resume(at: now()) }
        else { value?.clock.pause(at: now()) }
    }

    func detach(_ owner: UUID) {
        owners.removeValue(forKey: owner)
        if !owners.values.contains(true) { value?.clock.pause(at: now()) }
    }

    func finish() {
        guard var value else { return }
        self.value = nil
        owners.removeAll()
        sink("ai", value.finish(at: now()))
    }
}

@MainActor
final class AIUsageSessions {
    private var sessions: [String: AIUsageSession] = [:]

    func finish(_ key: String) { sessions[key]?.finish() }
    func finishAll() { for session in sessions.values { session.finish() } }

    func session(_ key: String) -> AIUsageSession {
        if let session = sessions[key] { return session }
        let session = AIUsageSession()
        sessions[key] = session
        return session
    }
}
