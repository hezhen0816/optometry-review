import Foundation

/// Lightweight attempt value for the pure study-log functions (decoupled from SwiftData).
struct AttemptFact: Equatable {
    let questionID: String
    let timestamp: Date
    let correct: Bool
    /// From a mock exam (does not count toward the daily goal).
    let fromExam: Bool

    /// Stable tie handling for callers that already supplied persisted attempt order.
    static func chronological(_ attempts: [AttemptFact]) -> [AttemptFact] {
        attempts.enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
    }
}

/// Weekly activity: any answer counts as a study day; correct-only goal completion is a separate signal.
enum WeeklyGoal {
    static let targetDays = 5

    /// Calendar with Monday as the first weekday.
    static func mondayCalendar(_ base: Calendar = .current) -> Calendar {
        var c = base
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 1
        return c
    }

    /// Monday (start of day) of the week containing `date`.
    static func weekStart(of date: Date, calendar: Calendar) -> Date {
        let cal = mondayCalendar(calendar)
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
        let offset = (weekday + 5) % 7                    // Monday → 0 … Sunday → 6
        return cal.date(byAdding: .day, value: -offset, to: day)!
    }

    /// Distinct questions answered correctly per day outside mock exams (the daily-goal count).
    static func goalCounts(_ attempts: [AttemptFact], calendar: Calendar) -> [Date: Int] {
        var sets: [Date: Set<String>] = [:]
        for a in attempts where !a.fromExam && a.correct {
            sets[calendar.startOfDay(for: a.timestamp), default: []].insert(a.questionID)
        }
        return sets.mapValues(\.count)
    }

    /// Every answer counts for activity, including wrong answers and mocks.
    static func activityCounts(_ attempts: [AttemptFact], calendar: Calendar) -> [Date: Int] {
        Dictionary(grouping: attempts, by: { calendar.startOfDay(for: $0.timestamp) }).mapValues(\.count)
    }

    /// The 7 days of the current week with whether the daily goal was reached.
    struct Day: Equatable {
        let date: Date
        let count: Int
        let reached: Bool
        let isFuture: Bool
        let isToday: Bool
        var answeredCount: Int = 0
        var studied: Bool { !isFuture && answeredCount > 0 }
        var goalMet: Bool { reached }
    }

    static func week(counts: [Date: Int], goal: Int, now: Date, calendar: Calendar,
                     activityCounts: [Date: Int]? = nil) -> [Day] {
        let start = weekStart(of: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<7).map { i in
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            let n = counts[d] ?? 0
            return Day(date: d, count: n, reached: d <= today && goal > 0 && n >= goal,
                       isFuture: d > today, isToday: d == today, answeredCount: activityCounts?[d] ?? n)
        }
    }

    /// Use this overload for weekly dots; goalCounts alone cannot represent wrong-only or mock-only days.
    static func week(attempts: [AttemptFact], goal: Int, now: Date, calendar: Calendar) -> [Day] {
        let history = attempts.filter { $0.timestamp <= now }
        return week(counts: goalCounts(history, calendar: calendar), goal: goal, now: now, calendar: calendar,
                    activityCounts: activityCounts(history, calendar: calendar))
    }

    static func daysStudied(attempts: [AttemptFact], goal: Int, now: Date, calendar: Calendar) -> Int {
        week(attempts: attempts, goal: goal, now: now, calendar: calendar).filter(\.studied).count
    }

    /// Goal-completion count retained for existing callers; weekly activity uses daysStudied instead.
    static func daysReached(counts: [Date: Int], goal: Int, now: Date, calendar: Calendar) -> Int {
        week(counts: counts, goal: goal, now: now, calendar: calendar).filter(\.reached).count
    }
}

/// Daily answer counts for the heatmap (every answer, mock exams included).
enum StudyHeatmap {
    static let weeks = 5

    struct Cell: Equatable {
        let date: Date
        let count: Int
        /// 0 = none … 4 = most; nil for future days.
        let level: Int?
    }

    /// Distinct questions answered per day, all sources.
    static func counts(_ attempts: [AttemptFact], calendar: Calendar) -> [Date: Int] {
        var sets: [Date: Set<String>] = [:]
        for a in attempts { sets[calendar.startOfDay(for: a.timestamp), default: []].insert(a.questionID) }
        return sets.mapValues(\.count)
    }

    /// Buckets relative to the daily goal: 0, ≤ ½ goal, ≤ goal, ≤ 1½ goal, more.
    static func level(count: Int, goal: Int) -> Int {
        let g = max(1, goal)
        if count <= 0 { return 0 }
        if count * 2 <= g { return 1 }
        if count <= g { return 2 }
        if count * 2 <= g * 3 { return 3 }
        return 4
    }

    /// Upper bound of each level's range, for the legend ("1–10", "11–20" …).
    static func ranges(goal: Int) -> [String] {
        let g = max(1, goal)
        let half = max(1, g / 2), oneHalf = g * 3 / 2
        return ["0", "1–\(half)", "\(half + 1)–\(g)", "\(g + 1)–\(oneHalf)", "\(oneHalf + 1)+"]
    }

    /// The last `weeks` Monday-start weeks ending with the current week, row by row.
    static func cells(counts: [Date: Int], goal: Int, now: Date, calendar: Calendar) -> [Cell] {
        let thisWeek = WeeklyGoal.weekStart(of: now, calendar: calendar)
        let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek)!
        let today = calendar.startOfDay(for: now)
        return (0..<(7 * weeks)).map { i in
            let d = calendar.date(byAdding: .day, value: i, to: first)!
            let n = counts[d] ?? 0
            return Cell(date: d, count: n, level: d > today ? nil : level(count: n, goal: goal))
        }
    }
}

/// New-question vs review accuracy. A "new" answer is the first-ever attempt of that question; later ones are reviews.
enum AccuracySplit {
    struct Rate: Equatable {
        var correct = 0
        var total = 0
        var percent: Int? { total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : nil }
    }

    struct Result: Equatable {
        var new = Rate()
        var review = Rate()
    }

    /// Classifies every attempt against the full history, then keeps those at or after `since`.
    static func compute(_ attempts: [AttemptFact], since: Date? = nil) -> Result {
        var seen = Set<String>()
        var r = Result()
        for a in AttemptFact.chronological(attempts) {
            let isNew = seen.insert(a.questionID).inserted
            if let since, a.timestamp < since { continue }
            if isNew {
                r.new.total += 1
                if a.correct { r.new.correct += 1 }
            } else {
                r.review.total += 1
                if a.correct { r.review.correct += 1 }
            }
        }
        return r
    }
}

/// Mistake digestion: mastered vs still in review.
struct MistakeDigest: Equatable {
    var mastered: Int
    var reviewing: Int
    var total: Int { mastered + reviewing }
}
