import Foundation
import SwiftData

/// Pure population replay shared by migration and historical mistake classification.
enum ReviewHistory {
    struct Answer: Equatable {
        let questionID: String
        let timestamp: Date
        let outcome: ReviewOutcome
        var retry: Bool = false
        var masteredBefore: Bool? = nil
    }

    struct Result {
        var states: [String: ReviewSchedule]
        var anchors: [String: Date]
        var lastAnswers: [String: Date] = [:]
        var lastRelapses: [String: Date] = [:]
    }

    /// Equal timestamps retain the supplied order; persisted callers supply StudyReplay.attemptOrder.
    static func replay(_ answers: [Answer], scheduler: Scheduler,
                       initialStates: [String: ReviewSchedule] = [:], anchors: [String: Date] = [:],
                       excludingFromPreExam excluded: Set<String> = []) -> Result {
        var result = Result(states: initialStates, anchors: anchors)
        let windowStart = ExamDatePolicy(examDate: scheduler.examDate, calendar: scheduler.calendar).reviewWindowStart
        var baseline: [String: ReviewSchedule]?
        let ordered = answers.enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        for answer in ordered {
            if let windowStart, answer.timestamp >= windowStart, baseline == nil { baseline = result.states }
            let state = result.states[answer.questionID] ?? .unseen
            let outcome: ReviewOutcome = answer.retry && answer.outcome != .wrong ? .correct : answer.outcome
            if outcome == .wrong, answer.masteredBefore ?? scheduler.isMastered(state, at: answer.timestamp) {
                result.lastRelapses[answer.questionID] = answer.timestamp
            }
            var due: ReviewDue?
            if scheduler.isMastered(state, at: answer.timestamp), !excluded.contains(answer.questionID) {
                let items = result.states.filter { !excluded.contains($0.key) }.map { id, value in
                    PreExamReviewPlanner.Item(questionID: id, atWindowStart: baseline?[id] ?? value,
                                              current: value, lastAnswer: result.lastAnswers[id])
                }
                due = PreExamReviewPlanner.plan(items: items, scheduler: scheduler, now: answer.timestamp)[answer.questionID]
            }
            let early = scheduler.isEarlyCorrect(state, outcome: outcome, at: answer.timestamp, reviewDue: due)
            result.states[answer.questionID] = scheduler.next(state, outcome: outcome,
                                                              at: answer.timestamp, reviewDue: due)
            if !early { result.anchors[answer.questionID] = answer.timestamp }
            result.lastAnswers[answer.questionID] = answer.timestamp
        }
        return result
    }
}

/// One-time migration of answer history through exactly the live scheduling pipeline.
@MainActor
enum StudyReplay {
    /// Marker for cards whose stored state came from a full replay or a live answer. A1 (確認題) did not raise it:
    /// stored schedules are kept on upgrade and only cards the old rule left unscheduled are backfilled
    /// (`ConfirmationBackfill`). Replays of reset cards (merges, repairs, imports) use the current rule.
    static let version = 2

    /// Launch, iCloud merge and first join. Normal opens save nothing and fetch only the wrong or 猜的 attempts (when
    /// any 確認題 exist), never the whole history.
    static func run(context: ModelContext, scheduler: Scheduler, now: Date = .now) throws {
        var changed = try markInconsistentConfirmations(context: context)
        changed = try replayOutdated(context: context, scheduler: scheduler, now: now) || changed
        changed = try ConfirmationBackfill.run(context: context, scheduler: scheduler, now: now) || changed
        // State and marker become durable together; retries cannot double-apply a history.
        if changed { try context.save() }
    }

    /// A stored 確認題 with a wrong or 猜的 answer missed that answer (it arrived later through iCloud, or was saved
    /// out of order): reset its marker so the replay below rebuilds it as a mistake (and drops its backfill date).
    private static func markInconsistentConfirmations(context: ModelContext) throws -> Bool {
        let current = version
        let stored = try context.fetch(FetchDescriptor<QuestionRecord>(predicate: #Predicate {
            $0.fsrsVersion >= current && $0.reps > 0 && $0.lapses == 0 && $0.dueCorrectCount == $0.reps
        })).filter(\.schedule.isConfirmation)
        guard !stored.isEmpty else { return false }
        let mistaken = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate {
            !$0.correct || ($0.unsure && !$0.retry)
        }))
        let ids = Set(mistaken.filter { !$0.isAI }.map(\.questionID))
        var changed = false
        for record in stored where ids.contains(record.questionID) {
            record.fsrsVersion = 0
            changed = true
        }
        return changed
    }

    private static func replayOutdated(context: ModelContext, scheduler: Scheduler, now: Date) throws -> Bool {
        let current = version
        let descriptor = FetchDescriptor<QuestionRecord>(predicate: #Predicate { $0.fsrsVersion < current })
        let records = try context.fetch(descriptor)
        // The marker includes unscheduled correct-only histories.
        guard !records.isEmpty else { return false }
        let allRecords = try context.fetch(FetchDescriptor<QuestionRecord>())
        let byID = Dictionary(allRecords.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
        // AI-question attempts never schedule anything (docs/AI出題與圖解.md §4).
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>()).filter { !$0.isAI && byID[$0.questionID] != nil }
        let historyIDs = Set(attempts.map(\.questionID))
        let states = byID.mapValues {
            historyIDs.contains($0.questionID) || $0.fsrsVersion < version ? ReviewSchedule.unseen : $0.schedule
        }
        let result = ReviewHistory.replay(attempts.sorted(by: attemptOrder).map {
            .init(questionID: $0.questionID, timestamp: $0.timestamp,
                  outcome: ReviewOutcome(correct: $0.correct, unsure: $0.unsure), retry: $0.retry,
                  masteredBefore: $0.masteredBefore)
        }, scheduler: scheduler, initialStates: states, anchors: byID.mapValues(\.firstSeen),
           excludingFromPreExam: Set(allRecords.filter(\.parked).map(\.questionID)))
        for attempt in attempts {
            if attempt.record == nil { attempt.record = byID[attempt.questionID] }
        }
        for record in records {
            let replayed = result.states[record.questionID] ?? .unseen
            // Local answers can lag behind the card (iCloud still importing): never let them turn a stored mistake into
            // a 確認題 or unseen. Keep the stored state and the old marker, so a later launch replays again.
            if record.schedule.isMistake && !replayed.isMistake { continue }
            record.schedule = replayed
            // A backfill date belongs to a 確認題: a merge or import can carry it onto a card whose full history is a
            // mistake, which must then come back on its own FSRS date instead of weeks later. Unpark dates are kept
            // (stamped `parkedAt`, or from before 0.3.0 and long past), as is any date that delays nothing.
            if replayed.isMistake, let resume = record.resumeDueDate, let due = replayed.due,
               resume > due, resume > scheduler.calendar.startOfDay(for: now),
               !isUnparkDate(record, calendar: scheduler.calendar) {
                record.resumeDueDate = nil
            }
            // A pending unpark or backfill review survives repairs without changing the replayed memory.
            if let resume = record.resumeDueDate, record.schedule.isScheduled { record.dueDate = resume }
            record.lastAnswered = result.anchors[record.questionID] ?? record.firstSeen
            record.fsrsVersion = version
        }
        return true
    }

    /// `unpark` sets the review to the day after `parkedAt` (which it stamps); a backfill date never matches, because
    /// the backfill only fills cards without a pending date and a later unpark overwrites both fields.
    static func isUnparkDate(_ record: QuestionRecord, calendar: Calendar) -> Bool {
        guard let resume = record.resumeDueDate, let parkedAt = record.parkedAt,
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: parkedAt))
        else { return false }
        return calendar.isDate(resume, inSameDayAs: dayAfter)
    }

    static func attemptOrder(_ a: AttemptRecord, _ b: AttemptRecord) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
        if a.questionID == b.questionID, a.answerOrder != b.answerOrder { return a.answerOrder < b.answerOrder }
        if a.questionID != b.questionID { return a.questionID < b.questionID }
        return String(describing: a.persistentModelID) < String(describing: b.persistentModelID)
    }
}

/// A1 upgrade: cards the old rule left unscheduled (first answers plainly correct) become 確認題; the overdue ones are
/// spread over the coming weeks instead of all due at once. Every other stored schedule is left as it is.
enum ConfirmationBackfill {
    /// Builds the 確認題 state of every unscheduled card answered only plainly correct. Once stored scheduled a card
    /// never qualifies again; the spread date lives in the synced `resumeDueDate`, which replays and merges keep.
    /// A card with a wrong or 猜的 answer here was scheduled on another device whose card has not arrived yet: left alone.
    @MainActor
    static func run(context: ModelContext, scheduler: Scheduler, now: Date) throws -> Bool {
        let unscheduled = try context.fetch(FetchDescriptor<QuestionRecord>(predicate: #Predicate { $0.dueDate == nil }))
            .filter { !$0.schedule.isScheduled }
        guard !unscheduled.isEmpty else { return false }
        let ids = Array(Set(unscheduled.map(\.questionID)))
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate { ids.contains($0.questionID) }))
            .filter { !$0.isAI }
        let byQuestion = Dictionary(grouping: attempts, by: \.questionID)
        let eligible = unscheduled.filter { record in
            guard let list = byQuestion[record.questionID], !list.isEmpty else { return false }
            return list.allSatisfy { $0.correct && (!$0.unsure || $0.retry) }
        }
        guard !eligible.isEmpty else { return false }
        let eligibleIDs = Set(eligible.map(\.questionID))
        let result = ReviewHistory.replay(attempts.filter { eligibleIDs.contains($0.questionID) }
            .sorted(by: StudyReplay.attemptOrder).map {
                .init(questionID: $0.questionID, timestamp: $0.timestamp,
                      outcome: ReviewOutcome(correct: $0.correct, unsure: $0.unsure), retry: $0.retry,
                      masteredBefore: $0.masteredBefore)
            }, scheduler: scheduler)
        let today = scheduler.calendar.startOfDay(for: now)
        let dates = plan(eligible.compactMap { record in
            guard !record.parked, record.resumeDueDate == nil, let state = result.states[record.questionID],
                  let due = state.due, due < today else { return nil }
            return .init(questionID: record.questionID, lastAnswer: result.lastAnswers[record.questionID] ?? due)
        }, scheduler: scheduler, now: now)
        var changed = false
        for record in eligible {
            guard let state = result.states[record.questionID], state.isScheduled else { continue }
            record.schedule = state
            if let date = dates[record.questionID] { record.resumeDueDate = date }
            if let resume = record.resumeDueDate { record.dueDate = resume }
            record.fsrsVersion = StudyReplay.version
            changed = true
        }
        return changed
    }

    /// Spread over the next three weeks (day 1 … day 21).
    static let spreadDays = 21

    struct Candidate: Equatable {
        let questionID: String
        let lastAnswer: Date
    }

    /// Review day per card: longest-ago answered first, evenly over `spreadDays` from tomorrow. With an exam date the
    /// spread ends by exam − 3 days (the latest review day), but never before tomorrow.
    static func plan(_ candidates: [Candidate], scheduler: Scheduler, now: Date) -> [String: Date] {
        guard !candidates.isEmpty else { return [:] }
        let calendar = scheduler.calendar
        let today = calendar.startOfDay(for: now)
        var days = spreadDays
        let policy = ExamDatePolicy(examDate: scheduler.examDate, calendar: calendar)
        if policy.isActive(at: now), let examDate = scheduler.examDate {
            let lead = scheduler.addDays(-ExamDatePolicy.leadDays, to: calendar.startOfDay(for: examDate))
            let available = calendar.dateComponents([.day], from: today, to: lead).day ?? days
            days = max(1, min(days, available))
        }
        let ordered = candidates.sorted { ($0.lastAnswer, $0.questionID) < ($1.lastAnswer, $1.questionID) }
        var result: [String: Date] = [:]
        for (index, candidate) in ordered.enumerated() {
            result[candidate.questionID] = scheduler.addDays(1 + index * days / ordered.count, to: today)
        }
        return result
    }
}
