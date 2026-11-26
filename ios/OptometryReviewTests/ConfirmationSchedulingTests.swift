import XCTest
import SwiftData
@testable import OptometryReview

/// A1: a first plain-correct answer schedules a 確認題; their daily share, the upgrade backfill and replay consistency.
final class ConfirmationSchedulingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    private func day(_ offset: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour))!)!
    }

    private func question(_ id: String, subject: String = Subjects.all[0]) -> Question {
        Question(id: id, code: "115100", year: 115, examKind: "一般", subject: subject, number: 1, stem: "test",
                 options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A",
                 corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
    }

    private func days(_ from: Date, _ to: Date?) -> Int? {
        to.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: $0).day! }
    }

    @MainActor
    private func container() throws -> ModelContainer {
        try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    // MARK: Scheduler

    func testFirstPlainCorrectSchedulesTheFSRSEasyInterval() {
        let s = Scheduler(calendar: calendar)
        let now = day(0)
        let easy = FSRS().review(nil, rating: .easy, elapsedDays: 0)
        XCTAssertEqual(easy.intervalDays, 8, "default parameters give about 8 days")
        let state = s.next(.unseen, outcome: .correct, at: now)
        XCTAssertTrue(state.isScheduled)
        XCTAssertTrue(state.isConfirmation)
        XCTAssertFalse(state.isMistake)
        XCTAssertEqual(state.stability, easy.memory.stability)
        XCTAssertEqual(state.difficulty, easy.memory.difficulty)
        XCTAssertEqual(days(now, state.due), easy.intervalDays)
        XCTAssertEqual(state.reps, 1)
        XCTAssertEqual(state.lapses, 0)
        XCTAssertEqual(state.dueCorrectCount, 1)
        XCTAssertFalse(s.isOpenMistake(state, at: now))
        XCTAssertFalse(s.isMastered(state, at: now))
        let status = s.status(state, at: now)
        XCTAssertTrue(status.isConfirmation)
        XCTAssertFalse(status.isOpenMistake)
        // Retry answers only follow a wrong answer, so a retry flag on a first answer is still a plain correct.
        XCTAssertEqual(s.next(.unseen, outcome: ReviewOutcome(correct: true, unsure: false, retry: true), at: now), state)
    }

    func testWrongAndUnsureFirstAnswersAreUnchangedMistakes() {
        let s = Scheduler(calendar: calendar)
        let now = day(0)
        let wrong = s.next(.unseen, outcome: .wrong, at: now)
        XCTAssertEqual(days(now, wrong.due), FSRS().review(nil, rating: .again, elapsedDays: 0).intervalDays)
        XCTAssertTrue(wrong.isMistake)
        XCTAssertEqual(wrong.lapses, 1)
        let unsure = s.next(.unseen, outcome: .unsure, at: now)
        XCTAssertEqual(days(now, unsure.due), FSRS().review(nil, rating: .hard, elapsedDays: 0).intervalDays)
        XCTAssertTrue(unsure.isMistake)
        XCTAssertTrue(s.isOpenMistake(unsure, at: now))
    }

    func testConfirmationStaysConfirmationUntilWrongOrUnsure() {
        let s = Scheduler(calendar: calendar)
        let first = s.next(.unseen, outcome: .correct, at: day(0))
        // Early correct answers change nothing.
        XCTAssertEqual(s.next(first, outcome: .correct, at: day(3)), first)
        let confirmed = s.next(first, outcome: .correct, at: first.due!.addingTimeInterval(9 * 3600))
        XCTAssertTrue(confirmed.isConfirmation)
        XCTAssertEqual(confirmed.reps, 2)
        // Mastery rule unchanged: two correct answers in a row and a next interval of 21 days or more.
        XCTAssertGreaterThanOrEqual(days(confirmed.lastReview!, confirmed.due)!, 21)
        XCTAssertTrue(s.isMastered(confirmed, at: confirmed.lastReview!))
        let at = confirmed.due!.addingTimeInterval(9 * 3600)
        let wrong = s.next(confirmed, outcome: .wrong, at: at)
        XCTAssertTrue(wrong.isMistake)
        XCTAssertTrue(s.isOpenMistake(wrong, at: at))
        let guessed = s.next(confirmed, outcome: .unsure, at: at)
        XCTAssertTrue(guessed.isMistake)
        XCTAssertFalse(s.next(guessed, outcome: .correct, at: guessed.due!.addingTimeInterval(9 * 3600)).isConfirmation)
    }

    // MARK: Daily share

    func testConfirmationShareIsAThirdOfTheGoalMostOverdueFirst() {
        let d0 = day(-30)
        let confirmations = (0..<9).map {
            DailyPlanner.DueItem(id: "c\($0)", due: d0.addingTimeInterval(Double(8 - $0) * 86_400), subject: "S1",
                                 isConfirmation: true)
        }
        let mistakes = (0..<3).map { DailyPlanner.DueItem(id: "m\($0)", due: d0, subject: "S2") }
        let limit = DailyPlanner.confirmationLimit(goal: 20, reviewedToday: 0, examDate: nil, now: day(0),
                                                   calendar: calendar)
        XCTAssertEqual(limit, 7)
        let plan = DailyPlanner.plan(due: confirmations + mistakes, unseenBySubject: [:], accuracy: [:], goal: 20,
                                     answeredToday: 0, subjectOrder: ["S1", "S2"], confirmationLimit: limit)
        // Every mistake stays; only the seven most overdue 確認題 (c8 is the oldest) enter today.
        XCTAssertEqual(Set(plan.dueIDs), Set(["m0", "m1", "m2", "c8", "c7", "c6", "c5", "c4", "c3", "c2"]))
        // The rest are deferred, not dropped: tomorrow they come first.
        let tomorrow = DailyPlanner.limitConfirmations(confirmations.filter { !plan.dueIDs.contains($0.id) }, to: 7)
        XCTAssertEqual(tomorrow.map(\.id).sorted(), ["c0", "c1"])
        XCTAssertEqual(DailyPlanner.limitConfirmations(confirmations, to: 2).map(\.id).sorted(), ["c7", "c8"])
        // Reviewing some today uses up the share; nil means no limit.
        XCTAssertEqual(DailyPlanner.confirmationLimit(goal: 20, reviewedToday: 2, examDate: nil, now: day(0),
                                                      calendar: calendar), 5)
        XCTAssertEqual(DailyPlanner.confirmationLimit(goal: 20, reviewedToday: 9, examDate: nil, now: day(0),
                                                      calendar: calendar), 0)
        // A third of the goal, rounded: 20 → 7, 5 → 2, 30 → 10, 10 → 3.
        XCTAssertEqual(DailyPlanner.confirmationCap(goal: 20), 7)
        XCTAssertEqual(DailyPlanner.confirmationCap(goal: 5), 2)
        XCTAssertEqual(DailyPlanner.confirmationCap(goal: 30), 10)
        XCTAssertEqual(DailyPlanner.confirmationCap(goal: 10), 3)
        XCTAssertEqual(DailyPlanner.limitConfirmations(confirmations + mistakes, to: nil).count, 12)
    }

    func testConfirmationShareIsLiftedFromOneMonthBeforeTheExam() {
        let today = day(0)
        func limit(examIn offset: Int?) -> Int? {
            DailyPlanner.confirmationLimit(goal: 20, reviewedToday: 0,
                                           examDate: offset.map { calendar.startOfDay(for: day($0)) },
                                           now: today, calendar: calendar)
        }
        XCTAssertEqual(limit(examIn: nil), 7)
        XCTAssertEqual(limit(examIn: 60), 7)
        // 2026-10-22 → exam 2026-11-22: exactly one month ahead lifts the limit; one day more does not.
        XCTAssertNil(limit(examIn: 31))
        XCTAssertEqual(limit(examIn: 32), 7)
        XCTAssertNil(limit(examIn: 10))
        XCTAssertNil(limit(examIn: 1))
        // Exam day and after: the ordinary limit again.
        XCTAssertEqual(limit(examIn: 0), 7)
        XCTAssertEqual(limit(examIn: -3), 7)
    }

    @MainActor
    func testTodayPlanTakesSevenConfirmationsADayAndDefersTheRest() throws {
        let scheduler = Scheduler(calendar: calendar)
        let container = try container()
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let questions = (0..<16).map { question("c\($0)", subject: Subjects.all[$0 % Subjects.all.count]) }
        // Answered correctly on different days, so each is due 8 days later and overdue by today.
        for (index, q) in questions.enumerated() {
            store.commit(question: q, chosen: "A", correct: true, unsure: false, reason: nil, now: day(-30 + index))
        }
        let wrong = question("w0")
        store.commit(question: wrong, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-2))
        let early = question("e0")
        store.commit(question: early, chosen: "A", correct: true, unsure: false, reason: nil, now: day(-2))
        let bank = QuestionBank(questions: questions + [wrong, early])
        XCTAssertTrue(store.allRecords().filter { $0.questionID != wrong.id }.allSatisfy(\.schedule.isConfirmation))
        XCTAssertEqual(store.mistakeCategories(now: day(0)).all.ids, [wrong.id], "確認題 stay out of the 錯題本")

        var summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0))
        XCTAssertEqual(Set(summary.plan.dueIDs), Set([wrong.id] + questions.prefix(7).map(\.id)))
        // An early correct answer on a 確認題 that is not due yet changes nothing and uses no slot.
        let before = try XCTUnwrap(store.record(for: early.id)).schedule
        store.commit(question: early, chosen: "A", correct: true, unsure: false, reason: nil, now: day(0, hour: 9))
        XCTAssertEqual(try XCTUnwrap(store.record(for: early.id)).schedule, before)
        // Of today's seven, c0 is answered wrong and c1 猜的; the others correctly.
        for id in summary.plan.dueIDs where id != wrong.id {
            store.commit(question: bank.byID[id]!, chosen: id == "c0" ? "B" : "A", correct: id != "c0",
                         unsure: id == "c1", reason: nil, now: day(0, hour: 10))
        }
        XCTAssertTrue(try XCTUnwrap(store.record(for: "c0")).schedule.isMistake)
        XCTAssertTrue(try XCTUnwrap(store.record(for: "c1")).schedule.isMistake)
        XCTAssertEqual(StudyStore.confirmationsReviewed(attempts: store.allAttempts(), records: store.allRecords(),
                                                        since: calendar.startOfDay(for: day(0)), now: day(0, hour: 11)), 7)
        // Reopening 今日 the same day does not refill the share, not even the slots of the wrong and 猜的 answers.
        summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0, hour: 11))
        XCTAssertEqual(summary.plan.dueIDs, [wrong.id])
        // The next day the next most overdue seven come (c0 and c1 are now mistakes due tomorrow).
        summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(1))
        XCTAssertEqual(Set(summary.plan.dueIDs).subtracting([wrong.id, "c0", "c1"]), Set(questions[7..<14].map(\.id)))
        // One month before the exam the share is lifted: every due 確認題 is in today's plan.
        let examScheduler = Scheduler(calendar: calendar, examDate: calendar.startOfDay(for: day(25)))
        let examStore = StudyStore(context: container.mainContext, scheduler: examScheduler, usageSink: { _, _ in })
        summary = examStore.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(1))
        XCTAssertEqual(Set(summary.plan.dueIDs).subtracting([wrong.id, "c0", "c1"]), Set(questions[7...].map(\.id)))
    }

    // MARK: Backfill

    func testBackfillSpreadsOldestAnsweredFirstOverThreeWeeks() {
        let scheduler = Scheduler(calendar: calendar)
        let now = day(0, hour: 20)
        let candidates = (0..<78).map {
            ConfirmationBackfill.Candidate(questionID: String(format: "q%02d", $0),
                                           lastAnswer: day(-100 + ($0 * 7) % 78))
        }
        let plan = ConfirmationBackfill.plan(candidates.shuffled(), scheduler: scheduler, now: now)
        XCTAssertEqual(plan.count, 78)
        let offsets = plan.mapValues { days(now, $0)! }
        XCTAssertEqual(offsets.values.min(), 1, "never today")
        XCTAssertEqual(offsets.values.max(), ConfirmationBackfill.spreadDays)
        let perDay = Dictionary(grouping: offsets.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(perDay.count, 21)
        XCTAssertLessThanOrEqual(perDay.values.max()!, 4, "even spread, never all at once")
        // Longest ago first.
        let byAge = candidates.sorted { ($0.lastAnswer, $0.questionID) < ($1.lastAnswer, $1.questionID) }
        let ordered = byAge.map { offsets[$0.questionID]! }
        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertEqual(plan, ConfirmationBackfill.plan(candidates, scheduler: scheduler, now: now), "deterministic")
        // A near exam ends the spread on exam − 3 days.
        let exam = Scheduler(calendar: calendar, examDate: calendar.startOfDay(for: day(10)))
        let near = ConfirmationBackfill.plan(candidates, scheduler: exam, now: now).mapValues { days(now, $0)! }
        XCTAssertEqual(near.values.max(), 7)
        XCTAssertEqual(near.values.min(), 1)
        XCTAssertTrue(ConfirmationBackfill.plan([], scheduler: scheduler, now: now).isEmpty)
    }

    /// Old data: cards the pre-A1 app left unscheduled (fsrsVersion 2) get FSRS states and spread review days once.
    @MainActor
    func testUpgradeReplayBackfillsOldCorrectCardsOnceAndKeepsTheDatesThroughLaterReplays() throws {
        let scheduler = Scheduler(calendar: calendar)
        let container = try container()
        let context = container.mainContext
        func legacy(_ id: String, answers: [(Int, Bool, Bool)]) -> QuestionRecord {
            let record = QuestionRecord(questionID: id, subject: Subjects.all[0], now: day(answers[0].0))
            var state = ReviewSchedule.unseen
            for (offset, correct, unsure) in answers {
                let attempt = AttemptRecord(questionID: id, subject: Subjects.all[0], timestamp: day(offset),
                                            chosen: correct ? "A" : "B", correct: correct, reason: nil, unsure: unsure)
                attempt.record = record
                context.insert(attempt)
                // The old rule: a correct answer on an unscheduled card changed nothing.
                let outcome = ReviewOutcome(correct: correct, unsure: unsure)
                if !(outcome == .correct && !state.isScheduled) { state = scheduler.next(state, outcome: outcome, at: day(offset)) }
            }
            record.schedule = state
            record.lastAnswered = day(answers.last!.0)
            record.fsrsVersion = 2
            context.insert(record)
            return record
        }
        let old = (0..<6).map { legacy("old\($0)", answers: [(-60 + $0 * 5, true, false)]) }
        let twice = legacy("twice", answers: [(-50, true, false), (-48, true, false)])
        let recent = legacy("recent", answers: [(-3, true, false)])
        let mistake = legacy("mistake", answers: [(-40, true, false), (-30, false, false)])
        let guessed = legacy("guessed", answers: [(-20, true, true)])
        // An old card already reset by a duplicate merge (marker 0) is replayed with the new rule, not spread; it is
        // simply overdue and limited by the daily share.
        let merged = legacy("merged", answers: [(-45, true, false)])
        merged.fsrsVersion = 0
        try context.save()
        XCTAssertTrue((old + [twice, recent]).allSatisfy { !$0.schedule.isScheduled })
        let mistakeBefore = mistake.schedule, guessedBefore = guessed.schedule

        let now = day(0, hour: 8)
        try StudyReplay.run(context: context, scheduler: scheduler, now: now)
        let backfilled = old + [twice]
        for record in backfilled {
            XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
            XCTAssertTrue(record.schedule.isConfirmation, record.questionID)
            let offset = try XCTUnwrap(days(now, record.resumeDueDate), record.questionID)
            XCTAssertTrue((1...ConfirmationBackfill.spreadDays).contains(offset), record.questionID)
            XCTAssertEqual(record.dueDate, record.resumeDueDate)
            XCTAssertEqual(scheduler.effectiveDue(record.schedule, now: now, reviewDue: record.resumeReviewDue),
                           record.resumeDueDate)
        }
        // Longest ago first: old0 (60 days ago) before twice (48) before old5 (35).
        let offsets = backfilled.map { days(now, $0.resumeDueDate)! }
        XCTAssertLessThanOrEqual(offsets[0], days(now, twice.resumeDueDate)!)
        XCTAssertLessThanOrEqual(days(now, twice.resumeDueDate)!, offsets[5])
        // A recent answer keeps its own FSRS date (5 days from now).
        XCTAssertNil(recent.resumeDueDate)
        XCTAssertEqual(days(now, recent.dueDate), 5)
        // Already scheduled cards keep their stored state, dates and mastery exactly (no recompute on upgrade).
        XCTAssertNil(mistake.resumeDueDate)
        XCTAssertEqual(mistake.schedule, mistakeBefore)
        XCTAssertNil(guessed.resumeDueDate)
        XCTAssertEqual(guessed.schedule, guessedBefore)
        XCTAssertNil(merged.resumeDueDate)
        XCTAssertTrue(merged.schedule.isConfirmation)
        XCTAssertTrue(scheduler.isDue(merged.schedule, on: now))

        // Idempotent: a second run changes nothing; a later full replay of the 確認題 (dedup or import reset) keeps
        // every date. (A reset mistake would be rebuilt with the new rule: accepted drift.)
        let all = old + [twice, recent, mistake, guessed]
        let snapshot = all.map { ($0.schedule, $0.resumeDueDate) }
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(2))
        for (record, before) in zip(all, snapshot) {
            XCTAssertEqual(record.resumeDueDate, before.1, record.questionID)
            XCTAssertEqual(record.schedule, before.0, record.questionID)
        }
        let confirmations = old + [twice, recent]
        for record in confirmations { record.fsrsVersion = 0 }
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(5))
        for (record, before) in zip(confirmations, snapshot) {
            XCTAssertEqual(record.resumeDueDate, before.1, record.questionID)
            XCTAssertEqual(record.schedule, before.0, record.questionID)
            XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
        }
        // A recent card that is overdue by the time of a later replay is not re-spread: it was stored scheduled.
        recent.fsrsVersion = 0
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(30))
        XCTAssertNil(recent.resumeDueDate)

        // Answering a backfilled card on its day consumes the date and advances FSRS as a due review.
        let store = StudyStore(context: context, scheduler: scheduler, usageSink: { _, _ in })
        let target = old[0]
        let early = store.commit(question: question(target.questionID), chosen: "A", correct: true, unsure: false,
                                 reason: nil, now: day(0, hour: 9))
        XCTAssertEqual(early.reps, 1, "before its day an answer is early practice")
        XCTAssertNotNil(target.resumeDueDate)
        let onDay = target.resumeDueDate!.addingTimeInterval(10 * 3600)
        let advanced = store.commit(question: question(target.questionID), chosen: "A", correct: true, unsure: false,
                                    reason: nil, now: onDay)
        XCTAssertEqual(advanced.reps, 2)
        XCTAssertTrue(advanced.isConfirmation)
        XCTAssertNil(target.resumeDueDate)
    }

    /// Two devices that upgrade on their own replay the same history to the same FSRS states; only the spread day
    /// depends on when each ran.
    @MainActor
    func testBackfillReplayIsTheSameOnTwoDevices() throws {
        let scheduler = Scheduler(calendar: calendar)
        var results: [[String: ReviewSchedule]] = []
        var resumes: [[String: Date]] = []
        for _ in 0..<2 {
            let container = try container()
            let context = container.mainContext
            for index in 0..<10 {
                let id = "dev\(index)"
                let record = QuestionRecord(questionID: id, subject: Subjects.all[0], now: day(-40 + index))
                record.fsrsVersion = 2
                context.insert(record)
                let attempt = AttemptRecord(questionID: id, subject: Subjects.all[0], timestamp: day(-40 + index),
                                            chosen: "A", correct: true, reason: nil, unsure: false)
                attempt.record = record
                context.insert(attempt)
            }
            try context.save()
            try StudyReplay.run(context: context, scheduler: scheduler, now: day(0))
            let records = try context.fetch(FetchDescriptor<QuestionRecord>())
            results.append(Dictionary(uniqueKeysWithValues: records.map { ($0.questionID, $0.schedule) }))
            resumes.append(Dictionary(uniqueKeysWithValues: records.compactMap { r in r.resumeDueDate.map { (r.questionID, $0) } }))
        }
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(resumes[0], resumes[1])
        XCTAssertEqual(resumes[0].count, 10)
    }

    // MARK: iCloud lag

    /// Answers arrive through iCloud after the card: a replay or backfill on incomplete local answers must never turn
    /// a mistake into a 確認題 (it would leave the 錯題本 and sync back).
    @MainActor
    func testPartialLocalAttemptsNeverDowngradeAStoredMistake() throws {
        let scheduler = Scheduler(calendar: calendar)
        let container = try container()
        let context = container.mainContext
        func attempt(_ id: String, _ offset: Int, correct: Bool, unsure: Bool = false, record: QuestionRecord) {
            let a = AttemptRecord(questionID: id, subject: Subjects.all[0], timestamp: day(offset),
                                  chosen: correct ? "A" : "B", correct: correct, reason: nil, unsure: unsure)
            a.record = record
            context.insert(a)
        }
        // Full history on another device: correct, then wrong. Here only the correct answer has arrived, and the card
        // was reset by a duplicate merge (marker 0).
        var full = scheduler.next(.unseen, outcome: .correct, at: day(-40))
        full = scheduler.next(full, outcome: .wrong, at: day(-30))
        let merged = QuestionRecord(questionID: "merged", subject: Subjects.all[0], now: day(-40))
        merged.schedule = full
        merged.fsrsVersion = 0
        context.insert(merged)
        attempt("merged", -40, correct: true, record: merged)
        // A mistake card whose answers have not arrived at all.
        let bare = QuestionRecord(questionID: "bare", subject: Subjects.all[0], now: day(-10))
        bare.schedule = scheduler.next(.unseen, outcome: .unsure, at: day(-10))
        bare.fsrsVersion = 0
        context.insert(bare)
        // An old unscheduled card whose newer copy (a mistake) has not arrived, though its wrong answer has.
        let stale = QuestionRecord(questionID: "stale", subject: Subjects.all[0], now: day(-50))
        stale.fsrsVersion = 2
        context.insert(stale)
        attempt("stale", -50, correct: true, record: stale)
        attempt("stale", -20, correct: false, record: stale)
        try context.save()

        for run in 0..<2 {
            try StudyReplay.run(context: context, scheduler: scheduler, now: day(run))
            XCTAssertEqual(merged.schedule, full)
            XCTAssertEqual(merged.fsrsVersion, 0, "not marked, so a later launch retries")
            XCTAssertEqual(bare.fsrsVersion, 0)
            XCTAssertTrue(bare.schedule.isMistake)
            XCTAssertFalse(stale.schedule.isScheduled, "left for the card that is still syncing")
            XCTAssertNil(stale.resumeDueDate)
        }
        XCTAssertEqual(StudyStore(context: context, scheduler: scheduler, usageSink: { _, _ in })
            .mistakeCategories(now: day(1)).all.ids, ["bare", "merged"])

        // The wrong answer arrives: the next replay rebuilds the mistake and marks it.
        attempt("merged", -30, correct: false, record: merged)
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(2))
        XCTAssertEqual(merged.fsrsVersion, StudyReplay.version)
        XCTAssertEqual(merged.schedule, full)

        // A card stored as 確認題 (backfilled before its 猜的 answer arrived) is rebuilt as a mistake once it does.
        let confirmed = QuestionRecord(questionID: "confirmed", subject: Subjects.all[0], now: day(-60))
        confirmed.fsrsVersion = 2
        context.insert(confirmed)
        attempt("confirmed", -60, correct: true, record: confirmed)
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(2))
        XCTAssertTrue(confirmed.schedule.isConfirmation)
        XCTAssertNotNil(confirmed.resumeDueDate)
        attempt("confirmed", -55, correct: true, unsure: true, record: confirmed)
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(2, hour: 12))
        XCTAssertTrue(confirmed.schedule.isMistake)
        XCTAssertEqual(confirmed.fsrsVersion, StudyReplay.version)
        // The spread date belonged to the 確認題; the mistake is due on its own FSRS date.
        XCTAssertNil(confirmed.resumeDueDate)
        XCTAssertTrue(scheduler.isDue(confirmed.schedule, on: day(2, hour: 12)))
    }

    /// Device A backfilled Q 15 days out; device B's copy was answered wrong. After the merge (marker 0, the later
    /// `resumeDueDate` kept) Q is a mistake due on its FSRS date, not on day 15. An unpark date survives.
    @MainActor
    func testMergedMistakeDropsBackfillDateButKeepsUnparkDate() throws {
        let scheduler = Scheduler(calendar: calendar)
        let container = try container()
        let context = container.mainContext
        let store = StudyStore(context: context, scheduler: scheduler, usageSink: { _, _ in })
        let q = question("merged-q")
        store.commit(question: q, chosen: "A", correct: true, unsure: false, reason: nil, now: day(-60))
        store.commit(question: q, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-1))
        let record = try XCTUnwrap(store.record(for: q.id))
        // What the merge leaves: A's 確認題 state and spread date, B's wrong answer, marker reset.
        record.schedule = scheduler.next(.unseen, outcome: .correct, at: day(-60))
        record.resumeDueDate = calendar.startOfDay(for: day(15))
        record.dueDate = record.resumeDueDate
        record.fsrsVersion = 0
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(0))
        XCTAssertTrue(record.schedule.isMistake)
        XCTAssertNil(record.resumeDueDate)
        let fsrsDue = try XCTUnwrap(scheduler.next(scheduler.next(.unseen, outcome: .correct, at: day(-60)),
                                                   outcome: .wrong, at: day(-1)).due)
        XCTAssertEqual(record.dueDate, fsrsDue)
        XCTAssertLessThan(fsrsDue, calendar.startOfDay(for: day(3)), "back within days, not on day 15")

        // Parked and unparked today: the review tomorrow is kept through a replay.
        XCTAssertTrue(store.park(questionID: q.id, now: day(0, hour: 10)))
        XCTAssertTrue(store.unpark(questionID: q.id, now: day(0, hour: 11)))
        let tomorrow = calendar.startOfDay(for: day(1))
        XCTAssertEqual(record.resumeDueDate, tomorrow)
        record.fsrsVersion = 0
        try context.save()
        try StudyReplay.run(context: context, scheduler: scheduler, now: day(0, hour: 12))
        XCTAssertTrue(record.schedule.isMistake)
        XCTAssertEqual(record.resumeDueDate, tomorrow)
        XCTAssertEqual(record.dueDate, tomorrow)
    }

    // MARK: Replay consistency

    /// New answers after the upgrade: a replay of the attempts (iCloud merge, import) reproduces the live states.
    @MainActor
    func testReplayOfLiveConfirmationHistoriesMatchesLive() throws {
        let scheduler = Scheduler(calendar: calendar)
        let live = try container()
        let store = StudyStore(context: live.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        // (day offset, correct, unsure)
        let histories: [[(Int, Bool, Bool)]] = [
            [(0, true, false)],
            [(0, true, false), (3, true, false)],
            [(0, true, false), (8, true, false)],
            [(0, true, false), (8, true, false), (60, false, false), (61, true, false)],
            [(0, true, false), (9, true, true)],
            [(1, false, false), (2, true, false)],
            [(1, true, true), (2, true, false)],
        ]
        for (index, history) in histories.enumerated() {
            let q = question("live\(index)")
            for (offset, correct, unsure) in history {
                store.commit(question: q, chosen: correct ? "A" : "B", correct: correct, unsure: unsure, reason: nil,
                             now: day(offset, hour: 10))
            }
        }
        let replay = try container()
        for record in store.allRecords() {
            // Fresh cards as after an import; the live schedule is never copied.
            replay.mainContext.insert(QuestionRecord(questionID: record.questionID, subject: record.subject,
                                                     now: record.firstSeen))
        }
        for attempt in store.allAttempts().reversed() {
            replay.mainContext.insert(AttemptRecord(questionID: attempt.questionID, subject: attempt.subject,
                timestamp: attempt.timestamp, chosen: attempt.chosen, correct: attempt.correct,
                reason: attempt.reason, unsure: attempt.unsure, source: attempt.source))
        }
        try replay.mainContext.save()
        // Long after every 確認題 date: fresh cards (marker 0) are never spread, so the replay equals the live states.
        try StudyReplay.run(context: replay.mainContext, scheduler: scheduler, now: day(120))
        let target = StudyStore(context: replay.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        for record in store.allRecords() {
            let replayed = try XCTUnwrap(target.record(for: record.questionID))
            XCTAssertEqual(replayed.schedule, record.schedule, record.questionID)
            XCTAssertEqual(replayed.lastAnswered, record.lastAnswered, record.questionID)
            XCTAssertNil(replayed.resumeDueDate)
        }
        XCTAssertTrue(try XCTUnwrap(store.record(for: "live0")).schedule.isConfirmation)
        XCTAssertTrue(try XCTUnwrap(store.record(for: "live3")).schedule.isMistake)
        XCTAssertTrue(try XCTUnwrap(store.record(for: "live4")).schedule.isMistake)

        // A dedup reset of a live, overdue 確認題 replays to the same state without a backfill date.
        let card = try XCTUnwrap(store.record(for: "live0"))
        let before = card.schedule
        card.fsrsVersion = 0
        try live.mainContext.save()
        try StudyReplay.run(context: live.mainContext, scheduler: scheduler, now: day(90))
        XCTAssertEqual(card.schedule, before)
        XCTAssertNil(card.resumeDueDate)
    }
}
