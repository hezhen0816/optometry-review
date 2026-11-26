import Foundation

/// Value snapshots keep category computation independent of SwiftData and UI state.
enum MistakeCategories {
    enum Category: String, CaseIterable {
        case all, recent, frequent, relapsed, parked
    }

    struct Record: Equatable {
        let questionID: String
        let schedule: ReviewSchedule
        var parked: Bool = false
    }

    struct Group: Equatable {
        var ids: [String]
        var count: Int { ids.count }
    }

    struct Result: Equatable {
        let all: Group
        let recent: Group
        let frequent: Group
        let relapsed: Group
        let parked: Group

        subscript(_ category: Category) -> Group {
            switch category {
            case .all: return all
            case .recent: return recent
            case .frequent: return frequent
            case .relapsed: return relapsed
            case .parked: return parked
            }
        }
    }

    /// Recent = rolling seven days, frequent = at least three lifetime wrong answers.
    /// Relapsed = any wrong answer whose pre-answer replay state was mastered (not today's mastery).
    static func compute(records: [Record], attempts: [ReviewHistory.Answer], scheduler: Scheduler,
                        now: Date) -> Result {
        let parkedIDs = Set(records.filter(\.parked).map(\.questionID))
        let active = Set(records.filter { !$0.parked }.map(\.questionID))
        let history = attempts.filter { $0.timestamp <= now }
        let wrong = history.filter { $0.outcome == .wrong && active.contains($0.questionID) }
        let since = scheduler.calendar.date(byAdding: .day, value: -7, to: now)!
        let wrongCounts = Dictionary(grouping: wrong, by: \.questionID).mapValues(\.count)
        // Replay the full population, including parked histories, before filtering category membership.
        let replay = ReviewHistory.replay(history, scheduler: scheduler)
        func group(_ ids: Set<String>) -> Group { Group(ids: ids.sorted()) }
        return Result(all: group(Set(records.filter { !$0.parked && $0.schedule.isMistake }.map(\.questionID))),
                      recent: group(Set(wrong.filter { $0.timestamp >= since }.map(\.questionID))),
                      frequent: group(Set(wrongCounts.filter { $0.value >= 3 }.map(\.key))),
                      relapsed: group(Set(replay.lastRelapses.keys).intersection(active)),
                      parked: group(parkedIDs))
    }
}
