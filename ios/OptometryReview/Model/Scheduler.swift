import Foundation

/// Current FSRS state. Due is the uncompressed FSRS date; mastery is evaluated by Scheduler.
struct ReviewSchedule: Equatable {
    var stability: Double = 0
    var difficulty: Double = 0
    var reps: Int = 0
    var lapses: Int = 0
    var lastReview: Date? = nil
    var due: Date? = nil
    /// Due, plain-correct reviews since the most recent Again or Hard (a 確認題's first answer counts as one).
    var dueCorrectCount: Int = 0

    static let unseen = ReviewSchedule()
    var isScheduled: Bool { reps > 0 && stability > 0 && lastReview != nil && due != nil }
    /// 確認題: scheduled only by plain-correct answers (the first one rated Easy), never wrong or 猜的. Every Again or
    /// Hard resets `dueCorrectCount` and only plain-correct reviews raise it, so equality with `reps` (and no lapse)
    /// identifies the card from the stored schedule alone, without its attempts.
    var isConfirmation: Bool { isScheduled && lapses == 0 && dueCorrectCount == reps }
    /// A scheduled card that was answered wrong or 猜的 at least once: the 錯題本 set (mastered or not).
    var isMistake: Bool { isScheduled && !isConfirmation }
}

/// Read-only UI snapshot; nothing here is persisted as a sticky mastery flag.
struct ReviewStatus: Equatable {
    let nextReviewDate: Date?
    let daysUntilNextReview: Int?
    let mastered: Bool
    let memoryStrength: Double
    let stabilityDays: Double
    let isScheduled: Bool
    /// 確認題 (see `ReviewSchedule.isConfirmation`): scheduled, but never a mistake.
    var isConfirmation: Bool = false
    var isOpenMistake: Bool { isScheduled && !isConfirmation && !mastered }
    /// Compatibility for the existing answer-sheet date formatter.
    var due: Date? { nextReviewDate }
}

/// Population-level pre-exam policy: nil means the ordinary single-record policy applies.
enum ReviewDue: Equatable {
    case scheduled(Date)
    case suppressed
    /// One explicit review after unpark, even during pre-exam rest.
    case resumed(Date)
}

enum ReviewOutcome: Equatable {
    case wrong
    case unsure
    case correct

    init(correct: Bool, unsure: Bool, retry: Bool = false) {
        if !correct { self = .wrong } else if unsure && !retry { self = .unsure } else { self = .correct }
    }

    var rating: FSRS.Rating {
        switch self {
        case .wrong: return .again
        case .unsure: return .hard
        case .correct: return .good
        }
    }
}

/// Scope and exam policies wrap the FSRS engine; they never replace its memory update.
struct Scheduler {
    var calendar: Calendar = .current
    var examDate: Date?
    private let fsrs = FSRS()
    private var policy: ExamDatePolicy { ExamDatePolicy(examDate: examDate, calendar: calendar) }

    init(calendar: Calendar = .current, examDate: Date? = nil) {
        self.calendar = calendar
        self.examDate = examDate
    }

    func next(_ state: ReviewSchedule, outcome: ReviewOutcome, at now: Date,
              reviewDue: ReviewDue? = nil) -> ReviewSchedule {
        if outcome == .correct, state.isScheduled {
            // Mastery is a label; every scheduled card advances when its effective review is due.
            guard isDue(state, on: now, reviewDue: reviewDue) else { return state }
        }
        let elapsed = state.lastReview.map { elapsedReviewDays(from: $0, to: now) } ?? 0
        let memory = state.isScheduled ? FSRS.Memory(stability: state.stability, difficulty: state.difficulty) : nil
        // A first plain-correct answer makes a 確認題: rated Easy, the longest FSRS first interval (about 8 days).
        let rating: FSRS.Rating = memory == nil && outcome == .correct ? .easy : outcome.rating
        let review = fsrs.review(memory, rating: rating, elapsedDays: elapsed)
        return ReviewSchedule(stability: review.memory.stability, difficulty: review.memory.difficulty,
                              reps: state.reps + 1, lapses: state.lapses + (outcome == .wrong ? 1 : 0),
                              lastReview: now,
                              due: addDays(review.intervalDays, to: calendar.startOfDay(for: now)),
                              dueCorrectCount: outcome == .correct ? state.dueCorrectCount + 1 : 0)
    }

    func isEarlyCorrect(_ state: ReviewSchedule, outcome: ReviewOutcome, at now: Date,
                        reviewDue: ReviewDue? = nil) -> Bool {
        outcome == .correct && state.isScheduled && !isDue(state, on: now, reviewDue: reviewDue)
    }

    /// Single authoritative mastery predicate, re-evaluated against the current exam date.
    func isMastered(_ state: ReviewSchedule, at now: Date) -> Bool {
        guard state.isScheduled, state.dueCorrectCount >= 2,
              let lastReview = state.lastReview, let due = state.due else { return false }
        if elapsedDays(from: lastReview, to: due) >= 21 { return true }
        guard let examDate, policy.isActive(at: now) else { return false }
        let cutoff = addDays(-ExamDatePolicy.leadDays, to: calendar.startOfDay(for: examDate))
        return due > cutoff
    }

    /// 確認題 are scheduled but never mistakes, so they stay out of the 錯題本 set.
    func isOpenMistake(_ state: ReviewSchedule, at now: Date) -> Bool {
        state.isMistake && !isMastered(state, at: now)
    }

    /// The stored FSRS due date is never overwritten by the exam clamp.
    func effectiveDue(_ state: ReviewSchedule, now: Date, reviewDue: ReviewDue? = nil) -> Date? {
        guard state.isScheduled, let lastReview = state.lastReview else { return nil }
        if let reviewDue, case .resumed(let date) = reviewDue { return date }
        if isMastered(state, at: now), policy.isActive(at: now), let start = policy.reviewWindowStart {
            // Mastered cards get one pre-exam review, then rest through the last three days.
            if (policy.daysUntilExam(from: now) ?? 0) <= ExamDatePolicy.leadDays { return nil }
            if lastReview >= start { return nil }
            if let reviewDue {
                switch reviewDue {
                case .scheduled(let date): return date
                case .resumed(let date): return date
                case .suppressed: return nil
                }
            }
            if let due = state.due, due < start, calendar.startOfDay(for: now) < start { return due }
            // A standalone state is a one-card cohort. StudyStore supplies the full-population assignment.
            return start
        }
        return policy.effectiveDue(stored: state.due, lastAnswered: lastReview, now: now)
    }

    func isDue(_ state: ReviewSchedule, on now: Date, reviewDue: ReviewDue? = nil) -> Bool {
        guard state.isScheduled, let due = effectiveDue(state, now: now, reviewDue: reviewDue) else { return false }
        return due <= calendar.startOfDay(for: now)
    }

    func status(_ state: ReviewSchedule, at now: Date, reviewDue: ReviewDue? = nil) -> ReviewStatus {
        let due = effectiveDue(state, now: now, reviewDue: reviewDue)
        let days = due.map { elapsedDays(from: now, to: $0, clampToZero: false) }
        return ReviewStatus(nextReviewDate: due, daysUntilNextReview: days,
                            mastered: isMastered(state, at: now), memoryStrength: memoryStrength(state, at: now),
                            stabilityDays: state.stability, isScheduled: state.isScheduled,
                            isConfirmation: state.isConfirmation)
    }

    func preview(_ state: ReviewSchedule, outcome: ReviewOutcome, at now: Date,
                 reviewDue: ReviewDue? = nil) -> ReviewStatus {
        var nextDue = reviewDue
        if let reviewDue, case .resumed = reviewDue,
           !isEarlyCorrect(state, outcome: outcome, at: now, reviewDue: reviewDue) { nextDue = nil }
        return status(next(state, outcome: outcome, at: now, reviewDue: reviewDue), at: now, reviewDue: nextDue)
    }

    func memoryStrength(_ state: ReviewSchedule, at now: Date) -> Double {
        state.lastReview.map {
            fsrs.retrievability(stability: state.stability, elapsedDays: Double(elapsedReviewDays(from: $0, to: now)))
        } ?? 0
    }

    private func elapsedDays(from: Date, to: Date, clampToZero: Bool = true) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                            to: calendar.startOfDay(for: to)).day ?? 0
        return clampToZero ? max(0, days) : days
    }

    /// Match py-fsrs timedelta.days; calendar midnight determines eligibility, not elapsed FSRS days.
    private func elapsedReviewDays(from: Date, to: Date) -> Int {
        Int(max(0, to.timeIntervalSince(from)) / 86_400)
    }

    func addDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: date)!
    }
}

/// Exam-date rules. Only active while the exam day is still in the future.
struct ExamDatePolicy {
    /// The last review is at least this many days before the exam.
    static let leadDays = 3
    /// From this many days before the exam, every open mistake is due daily.
    static let finalWindowDays = 14

    var examDate: Date?
    var calendar: Calendar = .current

    var reviewWindowStart: Date? {
        examDate.map { calendar.date(byAdding: .day, value: -Self.finalWindowDays, to: calendar.startOfDay(for: $0))! }
    }

    var reviewWindowEnd: Date? {
        examDate.map { calendar.date(byAdding: .day, value: -(Self.leadDays + 1), to: calendar.startOfDay(for: $0))! }
    }

    /// Whole days from today to the exam day; nil when no exam date is set.
    func daysUntilExam(from now: Date) -> Int? {
        guard let examDate else { return nil }
        let from = calendar.startOfDay(for: now), to = calendar.startOfDay(for: examDate)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    func isActive(at now: Date) -> Bool { (daysUntilExam(from: now) ?? 0) > 0 }

    func isFinalWindow(at now: Date) -> Bool {
        guard let d = daysUntilExam(from: now) else { return false }
        return d > 0 && d <= ExamDatePolicy.finalWindowDays
    }

    /// Latest allowed review day: exam day − 3, but never earlier than the day after `answeredAt`.
    func cap(answeredAt: Date) -> Date? {
        guard let examDate, isActive(at: answeredAt) else { return nil }
        let examDay = calendar.startOfDay(for: examDate)
        let lead = calendar.date(byAdding: .day, value: -ExamDatePolicy.leadDays, to: examDay)!
        return max(lead, dayAfter(answeredAt))
    }

    /// Due date for an answer given at `answeredAt`.
    func adjust(due: Date?, answeredAt: Date) -> Date? {
        guard let due, isActive(at: answeredAt) else { return due }
        if isFinalWindow(at: answeredAt) { return min(due, dayAfter(answeredAt)) }
        if let cap = cap(answeredAt: answeredAt) { return min(due, cap) }
        return due
    }

    /// Due date of a stored record seen today: the rules are re-applied so records scheduled before the exam date was
    /// set (or before the final window began) are pulled forward. A record answered today is never due again today.
    func effectiveDue(stored: Date?, lastAnswered: Date, now: Date) -> Date? {
        guard let stored, isActive(at: now) else { return stored }
        if isFinalWindow(at: now) { return min(stored, dayAfter(lastAnswered)) }
        guard let examDate else { return stored }
        let lead = calendar.date(byAdding: .day, value: -ExamDatePolicy.leadDays, to: calendar.startOfDay(for: examDate))!
        return min(stored, max(lead, dayAfter(lastAnswered)))
    }

    private func dayAfter(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
}
