import Foundation
import SwiftData

/// Eleven review days, exam minus fourteen through exam minus four, inclusive.
/// Completed cohort members keep their ranking slots so answering does not compact the remaining plan.
enum PreExamReviewPlanner {
    struct Item {
        let questionID: String
        let atWindowStart: ReviewSchedule
        let current: ReviewSchedule
        let lastAnswer: Date?
    }

    static func plan(items: [Item], scheduler: Scheduler, now: Date) -> [String: ReviewDue] {
        let policy = ExamDatePolicy(examDate: scheduler.examDate, calendar: scheduler.calendar)
        guard policy.isActive(at: now), let start = policy.reviewWindowStart else { return [:] }
        let today = scheduler.calendar.startOfDay(for: now)
        let cohort = items.filter { scheduler.isMastered($0.atWindowStart, at: start) }.sorted {
            // Rank the unchanged, pre-window memory at today's midnight for within-day determinism.
            let a = scheduler.memoryStrength($0.atWindowStart, at: today)
            let b = scheduler.memoryStrength($1.atWindowStart, at: today)
            return a == b ? $0.questionID < $1.questionID : a < b
        }
        guard !cohort.isEmpty else { return [:] }
        let dayCount = ExamDatePolicy.finalWindowDays - ExamDatePolicy.leadDays
        var result: [String: ReviewDue] = [:]
        for (index, item) in cohort.enumerated() {
            let reviewed = (item.lastAnswer ?? item.current.lastReview ?? .distantPast) >= start
            if reviewed || (policy.daysUntilExam(from: now) ?? 0) <= ExamDatePolicy.leadDays {
                result[item.questionID] = .suppressed
            } else if today < start, let due = item.current.due, due < start {
                result[item.questionID] = .scheduled(due)
            } else {
                let offset = index * dayCount / cohort.count
                result[item.questionID] = .scheduled(scheduler.addDays(offset, to: start))
            }
        }
        return result
    }

    @MainActor
    private final class CachedPlan {
        weak var context: ModelContext?
        let examDate: Date?
        let calendar: Calendar
        let day: Date
        let attemptCount: Int
        let result: [String: ReviewDue]

        init(context: ModelContext, scheduler: Scheduler, now: Date, attemptCount: Int,
             result: [String: ReviewDue]) {
            self.context = context
            examDate = scheduler.examDate
            calendar = scheduler.calendar
            day = scheduler.calendar.startOfDay(for: now)
            self.attemptCount = attemptCount
            self.result = result
        }
    }

    @MainActor private static var cached: [ObjectIdentifier: CachedPlan] = [:]

    /// Shared across short-lived StudyStore values and answer-sheet previews in one context.
    @MainActor
    static func cachedPlan(context: ModelContext, scheduler: Scheduler, now: Date,
                           onBuild: () -> Void = {}) -> [String: ReviewDue] {
        guard ExamDatePolicy(examDate: scheduler.examDate, calendar: scheduler.calendar).isActive(at: now)
        else { return [:] }
        let key = ObjectIdentifier(context)
        let count = (try? context.fetchCount(FetchDescriptor<AttemptRecord>())) ?? -1
        if !context.hasChanges, let entry = cached[key], entry.context === context,
           entry.examDate == scheduler.examDate, entry.calendar == scheduler.calendar,
           entry.day == scheduler.calendar.startOfDay(for: now), entry.attemptCount == count {
            return entry.result
        }
        onBuild()
        let records = (try? context.fetch(FetchDescriptor<QuestionRecord>())) ?? []
        let result = plan(records: records, scheduler: scheduler, now: now)
        cached = cached.filter { $0.value.context != nil }
        if !context.hasChanges, count >= 0 {
            cached[key] = CachedPlan(context: context, scheduler: scheduler, now: now,
                                     attemptCount: count, result: result)
        }
        return result
    }

    @MainActor
    static func invalidate(context: ModelContext) { cached.removeValue(forKey: ObjectIdentifier(context)) }

    /// Reconstruct the cohort from existing histories; nothing is stored as a separate plan.
    @MainActor
    static func plan(records: [QuestionRecord], scheduler: Scheduler, now: Date) -> [String: ReviewDue] {
        let policy = ExamDatePolicy(examDate: scheduler.examDate, calendar: scheduler.calendar)
        guard policy.isActive(at: now), let start = policy.reviewWindowStart else { return [:] }
        let active = records.filter { !$0.parked && $0.resumeDueDate == nil }
        let relevant = now < start ? active.filter { scheduler.isMastered($0.schedule, at: now) } : active
        let items = relevant.map { record -> Item in
            let history = (record.attempts ?? []).sorted(by: StudyReplay.attemptOrder)
            var baseline = record.schedule
            if now >= start, !history.isEmpty {
                baseline = .unseen
                for attempt in history where attempt.timestamp < start {
                    baseline = scheduler.next(baseline, outcome: ReviewOutcome(correct: attempt.correct, unsure: attempt.unsure,
                                                                              retry: attempt.retry),
                                              at: attempt.timestamp)
                }
            }
            return Item(questionID: record.questionID, atWindowStart: baseline, current: record.schedule,
                        lastAnswer: history.last?.timestamp ?? record.lastReview)
        }
        return plan(items: items, scheduler: scheduler, now: now)
    }

    @MainActor
    static func reviewDue(for record: QuestionRecord, scheduler: Scheduler, now: Date) -> ReviewDue? {
        guard !record.parked, record.resumeDueDate == nil,
              scheduler.isMastered(record.schedule, at: now), let context = record.modelContext,
              scheduler.examDate != nil else { return nil }
        return cachedPlan(context: context, scheduler: scheduler, now: now)[record.questionID]
    }
}
