import Foundation

/// Session-local order only. Recreate from the daily plan after relaunch; persist answers, never this queue.
struct RetryQueue: Equatable {
    private(set) var order: [String]
    private(set) var index = 0
    private(set) var retryIDs: Set<String>

    init(ids: [String], retryIDs: Set<String> = []) {
        var seen = Set<String>()
        order = ids.filter { seen.insert($0).inserted }
        self.retryIDs = retryIDs.intersection(seen)
    }

    var currentID: String? { order.indices.contains(index) ? order[index] : nil }
    var isRetry: Bool { currentID.map { retryIDs.contains($0) } ?? false }
    var remainingIDs: [String] { Array(order.dropFirst(index)) }

    /// Consumes the current item; wrong answers return after three intervening questions (or at the end).
    /// Returns the next index into the mutated order, or nil when complete. Capture isRetry before answering.
    @discardableResult
    mutating func answer(id: String, correct: Bool) -> Int? {
        guard currentID == id else { return currentID == nil ? nil : index }
        index += 1
        let prefix = Array(order.prefix(index))
        let suffix = order.dropFirst(index).filter { $0 != id }
        order = prefix + suffix
        if correct {
            retryIDs.remove(id)
        } else {
            retryIDs.insert(id)
            order.insert(id, at: min(index + 3, order.count))
        }
        return currentID == nil ? nil : index
    }

    /// Latest outcome today wins, regardless of source. Parked and inactive-pool IDs are filtered by the caller.
    static func rebuild(attempts: [AttemptFact], now: Date, calendar: Calendar,
                        excluding excluded: Set<String> = []) -> [String] {
        let start = calendar.startOfDay(for: now)
        var latest: [String: AttemptFact] = [:]
        for a in AttemptFact.chronological(attempts) where a.timestamp >= start && a.timestamp <= now {
            latest[a.questionID] = a
        }
        return latest.values.filter { !$0.correct && !excluded.contains($0.questionID) }
            .sorted { ($0.timestamp, $0.questionID) < ($1.timestamp, $1.questionID) }.map(\.questionID)
    }
}

/// What one round did, for its completion screen. Attempts are per question: a 「再練一次」 of the same
/// question does not count as another question.
struct RoundSummary: Equatable {
    private var first: [String: Bool] = [:]
    private var last: [String: Bool] = [:]

    mutating func record(_ id: String, correct: Bool) {
        if first[id] == nil { first[id] = correct }
        last[id] = correct
    }

    /// Distinct questions answered this round.
    var practiced: Int { first.count }
    /// Wrong at first, then answered right on a later 「再練一次」.
    var recovered: Int { first.filter { !$0.value && last[$0.key] == true }.count }
    /// Questions whose latest answer this round is still wrong (no retries in this session, or moved out of review).
    var stillWrong: Int { last.values.filter { !$0 }.count }

    /// Lines under the completion title. `retries`: wrong answers came back in this session.
    func lines(retries: Bool) -> [String] {
        var out = ["練了 \(practiced) 題"]
        if retries {
            if recovered > 0 { out.append("其中 \(recovered) 題答錯後再練到答對") }
            if stillWrong > 0 { out.append("\(stillWrong) 題這輪沒有答對") }
        } else if stillWrong > 0 {
            out.append("其中 \(stillWrong) 題答錯")
        }
        return out
    }

    /// True when this answer is the one that takes today's correct count up to the goal.
    static func reachedGoal(before: Int, after: Int, goal: Int) -> Bool {
        goal > 0 && before < goal && after >= goal
    }

    /// Questions still needed for today's goal; nil when there is no goal.
    static func goalLeft(correctToday: Int, goal: Int) -> Int? {
        goal > 0 ? max(0, goal - correctToday) : nil
    }
}
