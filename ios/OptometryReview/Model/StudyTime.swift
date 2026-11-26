import Foundation

/// Daily study metrics count answer attempts (retries included), separate from distinct correct daily progress.
enum StudyTime {
    static let maxGapSeconds: Double = 5 * 60
    static let focusDays = 30

    struct MockTime: Equatable {
        let date: Date
        let seconds: Double
    }

    struct Day: Equatable {
        let date: Date
        var seconds: Double = 0
        var answeredCount = 0
        var newAnsweredCount = 0
        var reviewAnsweredCount = 0
        var correctCount = 0
        var minutes: Double { seconds / 60 }
        /// Percent, or nil when there were no answers.
        var accuracy: Int? {
            answeredCount > 0 ? Int((Double(correctCount) / Double(answeredCount) * 100).rounded()) : nil
        }
    }

    struct Summary: Equatable {
        let today: Day
        let mostFocusedDay: Day?
        let days: [Day]
    }

    /// Non-exam consecutive answers on the same local day contribute gaps <= 5 minutes.
    /// Exam answers break that chain; their measured question seconds are added exactly once instead.
    static func compute(attempts: [AttemptFact], mocks: [MockTime] = [], now: Date,
                        calendar: Calendar) -> Summary {
        let today = calendar.startOfDay(for: now)
        var days: [Date: Day] = [:]
        var seen = Set<String>()
        var previous: AttemptFact?
        for answer in AttemptFact.chronological(attempts) where answer.timestamp <= now {
            let date = calendar.startOfDay(for: answer.timestamp)
            var day = days[date] ?? Day(date: date)
            day.answeredCount += 1
            if seen.insert(answer.questionID).inserted { day.newAnsweredCount += 1 }
            else { day.reviewAnsweredCount += 1 }
            if answer.correct { day.correctCount += 1 }
            if let previous, !previous.fromExam, !answer.fromExam,
               calendar.isDate(previous.timestamp, inSameDayAs: answer.timestamp) {
                let gap = answer.timestamp.timeIntervalSince(previous.timestamp)
                if gap >= 0 && gap <= maxGapSeconds { day.seconds += gap }
            }
            days[date] = day
            previous = answer
        }
        for mock in mocks where mock.date <= now && mock.seconds.isFinite && mock.seconds > 0 {
            let date = calendar.startOfDay(for: mock.date)
            var day = days[date] ?? Day(date: date)
            day.seconds += mock.seconds
            days[date] = day
        }
        let since = calendar.date(byAdding: .day, value: -(focusDays - 1), to: today)!
        let focused = days.values.filter { $0.date >= since && $0.date <= today && $0.answeredCount > 0 }.sorted {
            if $0.answeredCount != $1.answeredCount { return $0.answeredCount > $1.answeredCount }
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.date > $1.date
        }.first
        return Summary(today: days[today] ?? Day(date: today), mostFocusedDay: focused,
                       days: days.values.sorted { $0.date < $1.date })
    }
}
