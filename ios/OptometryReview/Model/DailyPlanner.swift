import Foundation

/// Reserves new questions inside the daily goal window while retaining the entire review backlog.
struct DailyPlanner {
    struct DueItem: Equatable {
        let id: String
        let due: Date
        let subject: String
        /// 確認題 (`ReviewSchedule.isConfirmation`): limited by `confirmationLimit`.
        var isConfirmation: Bool = false
    }

    struct SubjectAccuracy: Equatable {
        var correct: Int
        var total: Int
    }

    /// Subjects with fewer attempts than this are treated as unknown (full weight).
    static let minAttemptsForWeight = 5
    /// A subject with fewer distinct questions answered than this is 「很少練」 (warn colour on 今日, boosted in new picks).
    static let neglectThreshold = 40

    struct Plan: Equatable {
        let dueIDs: [String]
        let newIDs: [String]
        var dueBeforeNew: Int = 0
        var retryIDs: [String] = []
        var reviewIDs: [String] {
            let retries = Set(retryIDs)
            return retryIDs + dueIDs.filter { !retries.contains($0) }
        }
        var queue: [String] {
            Array(reviewIDs.prefix(dueBeforeNew)) + newIDs + Array(reviewIDs.dropFirst(dueBeforeNew))
        }
    }

    /// - Parameters:
    ///   - due: scheduled questions that are due today.
    ///   - unseenBySubject: never-attempted question ids per subject, in preferred order.
    ///   - accuracy: attempts per subject.
    ///   - goal: daily question count.
    ///   - answeredToday: compatibility fallback when correctToday is not supplied.
    ///   - correctToday: distinct non-exam questions answered correctly today.
    ///   - confirmationLimit: how many due 確認題 may still enter today's plan (nil = no limit). The most overdue go
    ///     first; the rest stay due and come back on the following days.
    static func plan(due: [DueItem],
                     unseenBySubject: [String: [String]],
                     accuracy: [String: SubjectAccuracy],
                     goal: Int,
                     answeredToday: Int,
                     newAnsweredToday: Int = 0,
                     subjectOrder: [String] = Subjects.all,
                     correctToday: Int? = nil,
                     retryIDs: [String] = [],
                     ratioMode: NewRatioMode = .normal,
                     customNewPercent: Int = SettingsKey.defaultCustomNewPercent,
                     confirmationLimit: Int? = nil,
                     answeredBySubject: [String: Int] = [:]) -> Plan {
        let due = limitConfirmations(due, to: confirmationLimit)
        let groups = Dictionary(grouping: due, by: \.subject).mapValues {
            $0.sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        }
        // Preserve unexpected subjects too; official subjects always lead each round.
        let order = subjectOrder + groups.keys.filter { !subjectOrder.contains($0) }.sorted()
        var dueIDs: [String] = []
        for index in 0..<(groups.values.map(\.count).max() ?? 0) {
            for subject in order {
                if let items = groups[subject], index < items.count { dueIDs.append(items[index].id) }
            }
        }
        var unique = Set<String>()
        let retries = retryIDs.filter { unique.insert($0).inserted }
        let reviewCount = Set(dueIDs + retries).count
        let remaining = max(0, goal - (correctToday ?? answeredToday))
        let quota = newQuota(goal: goal, mode: ratioMode, customPercent: customNewPercent)
        let newCount = ratioMode == .reviewOnly ? 0 : min(remaining, max(remaining - reviewCount, quota - newAnsweredToday, 0))
        let newIDs = pickNew(count: newCount, unseenBySubject: unseenBySubject, accuracy: accuracy, subjectOrder: subjectOrder,
                             answeredBySubject: answeredBySubject)
        return Plan(dueIDs: dueIDs, newIDs: newIDs,
                    dueBeforeNew: min(reviewCount, max(0, remaining - newIDs.count)), retryIDs: retries)
    }

    /// Keeps every mistake and the `limit` most overdue 確認題 (ties by id); nil keeps everything.
    static func limitConfirmations(_ due: [DueItem], to limit: Int?) -> [DueItem] {
        guard let limit else { return due }
        let kept = Set(due.filter(\.isConfirmation).sorted { ($0.due, $0.id) < ($1.due, $1.id) }
            .prefix(max(0, limit)).map(\.id))
        return due.filter { !$0.isConfirmation || kept.contains($0.id) }
    }

    /// Daily share of 確認題: a third of the goal, rounded (goal 20 → 7, at least 1).
    static func confirmationCap(goal: Int) -> Int { max(1, Int((Double(goal) / 3).rounded())) }

    /// 確認題 still allowed today, or nil when there is no limit: from one month before the exam day until the exam.
    /// `reviewedToday` are 確認題 already reviewed today, so reopening 今日 does not refill the share.
    static func confirmationLimit(goal: Int, reviewedToday: Int, examDate: Date?, now: Date,
                                  calendar: Calendar = .current) -> Int? {
        if let examDate {
            let examDay = calendar.startOfDay(for: examDate)
            let today = calendar.startOfDay(for: now)
            if let from = calendar.date(byAdding: .month, value: -1, to: examDay), today >= from, today < examDay {
                return nil
            }
        }
        return max(0, confirmationCap(goal: goal) - reviewedToday)
    }

    static func newQuota(goal: Int, mode: NewRatioMode, customPercent: Int = SettingsKey.defaultCustomNewPercent) -> Int {
        guard goal > 0 else { return 0 }
        switch mode {
        case .normal: return max(1, goal / 4)
        case .custom: return Int((Double(goal) * Double(NewRatioMode.normalizedPercent(customPercent)) / 100).rounded())
        case .reviewOnly: return 0
        }
    }

    /// Weight per subject: low accuracy → high weight. Subjects without enough data get full weight,
    /// so with no history the allocation is a plain round-robin in subject order.
    static func weight(for acc: SubjectAccuracy?) -> Double {
        guard let acc, acc.total >= minAttemptsForWeight else { return 1.0 }
        let rate = Double(acc.correct) / Double(acc.total)
        return max(0.1, 1.0 - rate)
    }

    /// Extra multiplier for a subject the learner has barely practised: 2 with nothing answered, falling linearly to 1
    /// at `neglectThreshold` answered. Subjects missing from `answeredBySubject` get no boost (unknown = 1).
    static func neglectBoost(answered: Int?) -> Double {
        guard let answered, answered < neglectThreshold else { return 1.0 }
        return 1.0 + Double(neglectThreshold - max(0, answered)) / Double(neglectThreshold)
    }

    /// D'Hondt-style allocation: each slot goes to the subject with the largest weight / (picked + 1), where the
    /// weight is the accuracy weight times the neglect boost. Ties resolve in subject order, which yields
    /// round-robin when weights are equal.
    static func pickNew(count: Int,
                        unseenBySubject: [String: [String]],
                        accuracy: [String: SubjectAccuracy],
                        subjectOrder: [String] = Subjects.all,
                        answeredBySubject: [String: Int] = [:]) -> [String] {
        guard count > 0 else { return [] }
        var remaining = unseenBySubject
        var picked: [String: Int] = [:]
        var result: [String] = []
        while result.count < count {
            var best: (subject: String, score: Double)?
            for s in subjectOrder {
                guard let pool = remaining[s], !pool.isEmpty else { continue }
                let score = weight(for: accuracy[s]) * neglectBoost(answered: answeredBySubject[s])
                    / Double((picked[s] ?? 0) + 1)
                if best == nil || score > best!.score + 1e-9 { best = (s, score) }
            }
            guard let chosen = best?.subject else { break }
            result.append(remaining[chosen]!.removeFirst())
            picked[chosen, default: 0] += 1
        }
        return result
    }
}

/// Deterministic RNG so the order of new questions stays stable within a day.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
