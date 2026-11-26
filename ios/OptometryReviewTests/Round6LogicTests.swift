import XCTest
import SwiftData
@testable import OptometryReview

final class Round6LogicTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    private func day(_ offset: Int = 0, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour))!)!
    }

    private func q(_ id: String, year: Int = 115, special: Bool = false) -> Question {
        Question(id: id, code: "115100", year: year, examKind: special ? ExamKind.special : ExamKind.general,
                 subject: Subjects.all[0], number: 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                 answer: ["A"], originalAnswer: "A", corrected: false, correctionNote: nil,
                 allCredit: false, hasFigure: false, needsReview: false)
    }

    private func fact(_ id: String, _ time: Date, correct: Bool = true, exam: Bool = false) -> AttemptFact {
        AttemptFact(questionID: id, timestamp: time, correct: correct, fromExam: exam)
    }

    // MARK: Session-local retries

    func testRetryWaitsForThreeInterveningQuestionsAndCorrectRemovesIt() {
        var queue = RetryQueue(ids: ["a", "b", "c", "d", "e"])
        XCTAssertFalse(queue.isRetry)
        XCTAssertEqual(queue.answer(id: "a", correct: false), 1)
        XCTAssertEqual(queue.order, ["a", "b", "c", "d", "a", "e"])
        for id in ["b", "c", "d"] { queue.answer(id: id, correct: true) }
        XCTAssertEqual(queue.currentID, "a")
        XCTAssertTrue(queue.isRetry)
        queue.answer(id: "a", correct: true)
        XCTAssertEqual(queue.remainingIDs, ["e"])
        XCTAssertFalse(queue.retryIDs.contains("a"))
        XCTAssertNil(queue.answer(id: "e", correct: true))
    }

    func testRetryAtEndAndRepeatedWrongHaveNoCap() {
        var short = RetryQueue(ids: ["a", "b"])
        short.answer(id: "a", correct: false)
        XCTAssertEqual(short.remainingIDs, ["b", "a"])
        short.answer(id: "b", correct: true)
        for _ in 0..<20 {
            XCTAssertEqual(short.currentID, "a")
            XCTAssertTrue(short.isRetry)
            XCTAssertNotNil(short.answer(id: "a", correct: false))
            XCTAssertEqual(short.remainingIDs, ["a"])
        }
        XCTAssertNil(short.answer(id: "a", correct: true))
        XCTAssertTrue(short.retryIDs.isEmpty)
    }

    func testRetryRebuildUsesLatestTodayOutcomeAllSourcesAndExcludesParked() {
        let t = day()
        let attempts = [fact("older", day(-1), correct: false), fact("fixed", t, correct: false),
                        fact("fixed", t.addingTimeInterval(1)), fact("wrongAgain", t),
                        fact("wrongAgain", t.addingTimeInterval(2), correct: false),
                        fact("mock", t.addingTimeInterval(3), correct: false, exam: true),
                        fact("parked", t.addingTimeInterval(4), correct: false),
                        fact("future", day(1), correct: false)]
        XCTAssertEqual(RetryQueue.rebuild(attempts: attempts.reversed(), now: day(hour: 20), calendar: calendar,
                                         excluding: ["parked"]), ["wrongAgain", "mock"])
    }

    @MainActor
    func testCorrectOnlyProgressRetryAttributionAndUnchangedEarlyFSRS() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var events: [(String, [String: Any])] = []
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar),
                               usageSink: { events.append(($0, $1)) })
        let wrong = q("wrong"), mock = q("mock"), older = q("older"), future = q("future")
        let bank = QuestionBank(questions: [wrong, mock, older, future])
        store.commit(question: older, chosen: "A", correct: true, unsure: false, reason: nil, now: day(-1))
        store.commit(question: future, chosen: "A", correct: true, unsure: false, reason: nil, now: day(1))
        store.commit(question: wrong, chosen: "", correct: false, unsure: false, reason: nil,
                     revealed: true, usageSource: "today", now: day())
        store.commit(question: mock, chosen: "A", correct: true, unsure: false, reason: nil,
                     source: AttemptRecord.examSource, now: day())
        let before = try XCTUnwrap(store.record(for: wrong.id)).schedule
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 1, now: day())
        XCTAssertEqual(summary.answeredToday, 1)
        XCTAssertEqual(summary.correctToday, 0)
        XCTAssertFalse(summary.goalMet(1))
        XCTAssertEqual(summary.retryIDs, [wrong.id])
        XCTAssertTrue(summary.plan.queue.contains(wrong.id))
        XCTAssertEqual(before.due, calendar.startOfDay(for: day(1)))
        XCTAssertEqual(store.preview(questionID: wrong.id, correct: true, unsure: true, retry: true, now: day()).stabilityDays,
                       before.stability)
        // Even an unsure correct retry finishes the challenge without another FSRS update.
        store.commit(question: wrong, chosen: "A", correct: true, unsure: true, reason: nil,
                     usageSource: "today", retry: true, now: day().addingTimeInterval(1))
        XCTAssertEqual(store.record(for: wrong.id)?.schedule, before)
        let done = store.todaySummary(bank: bank, includeSpecial: false, goal: 1, now: day(hour: 20))
        XCTAssertEqual(done.correctToday, 1)
        XCTAssertTrue(done.goalMet(1))
        XCTAssertTrue(done.retryIDs.isEmpty)
        store.commit(question: wrong, chosen: "A", correct: true, unsure: false, reason: nil,
                     now: day().addingTimeInterval(2))
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 1, now: day(hour: 20)).correctToday, 1)
        XCTAssertEqual(events.last { $0.1["retry"] as? Bool == true }?.1["qid"] as? String, wrong.id)
        XCTAssertEqual(events.last { $0.1["revealed"] as? Bool == true }?.1["correct"] as? Bool, false)
        store.commit(question: wrong, chosen: "B", correct: false, unsure: false, reason: nil,
                     now: day().addingTimeInterval(3))
        let wrongAgain = store.todaySummary(bank: bank, includeSpecial: false, goal: 1, now: day(hour: 20))
        XCTAssertEqual(wrongAgain.correctToday, 1, "an earlier correct answer still contributes to distinct correct progress")
        XCTAssertEqual(wrongAgain.retryIDs, [wrong.id])
    }

    @MainActor
    func testEveryNonExamSourceCountsDistinctCorrectQuestions() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        let sources = ["review", "extra", "mistakes", "practice", "custom"]
        let questions = sources.map { q($0) }
        for (index, source) in sources.enumerated() {
            store.commit(question: questions[index], chosen: "A", correct: true, unsure: false, reason: nil,
                         source: source, now: day())
        }
        store.commit(question: questions[0], chosen: "A", correct: true, unsure: false, reason: nil,
                     source: "custom", now: day().addingTimeInterval(1))
        let summary = store.todaySummary(bank: QuestionBank(questions: questions), includeSpecial: false, goal: 5,
                                         now: day(hour: 20))
        XCTAssertEqual(summary.correctToday, 5)
        XCTAssertTrue(summary.goalMet(5))
    }

    @MainActor
    func testRelaunchRebuildsRetriesFromSavedAttemptsAndEqualTimestampOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-retry-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: folder.appendingPathComponent("retry.store"),
                                        cloudKitDatabase: .none)
        let bank = QuestionBank(questions: [q("fixed"), q("pending")])
        do {
            let container = try StudyDataStore.open(config)
            let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
            for id in ["fixed", "pending"] {
                store.commit(question: q(id), chosen: "B", correct: false, unsure: false, reason: nil, now: day())
            }
            store.commit(question: q("fixed"), chosen: "A", correct: true, unsure: false, reason: nil, retry: true, now: day())
        }
        let reopened = try StudyDataStore.open(config)
        let store = StudyStore(context: reopened.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(hour: 20))
        XCTAssertEqual(summary.retryIDs, ["pending"])
        XCTAssertEqual(summary.correctToday, 1)
        XCTAssertEqual(RetryQueue(ids: summary.plan.queue, retryIDs: Set(summary.retryIDs)).currentID, "pending")
    }

    // MARK: 今日 counts

    /// The card's 待複習 + 再次挑戰 and the 今天要再練的錯題 rows count the same questions:
    /// wrong today (including 看解答 and mock exams) shows up under its subject, never as an empty state.
    @MainActor
    func testTodayReviewRowsAddUpToCardCounts() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        func q(_ id: String, _ subject: String) -> Question {
            Question(id: id, code: "115100", year: 115, examKind: ExamKind.general, subject: subject, number: 1,
                     stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A",
                     corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
        }
        let wrong = q("wrong", Subjects.all[0]), revealed = q("revealed", Subjects.all[2])
        let mock = q("mock", Subjects.all[1]), old = q("old", Subjects.all[3]), fresh = q("fresh", Subjects.all[4])
        let bank = QuestionBank(questions: [wrong, revealed, mock, old, fresh])
        let empty = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day())
        XCTAssertEqual(empty.reviewCount, 0)
        XCTAssertTrue(empty.reviewBySubject.isEmpty)

        // Missed three days ago, so it is a due review today rather than a retry.
        store.commit(question: old, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-3))
        store.commit(question: wrong, chosen: "B", correct: false, unsure: false, reason: nil, now: day())
        store.commit(question: revealed, chosen: "", correct: false, unsure: false, reason: nil, revealed: true,
                     now: day().addingTimeInterval(1))
        store.commit(question: mock, chosen: "B", correct: false, unsure: false, reason: nil,
                     source: AttemptRecord.examSource, now: day().addingTimeInterval(2))
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(hour: 20))
        XCTAssertEqual(summary.retryCount, 3)
        XCTAssertEqual(summary.reviewOnlyDueCount, 1)
        XCTAssertEqual(summary.reviewCount, summary.reviewOnlyDueCount + summary.retryCount)
        XCTAssertEqual(summary.reviewBySubject.values.reduce(0, +), summary.reviewCount)
        XCTAssertEqual(summary.reviewBySubject, [Subjects.all[0]: 1, Subjects.all[1]: 1, Subjects.all[2]: 1, Subjects.all[3]: 1])

        // A correct retry leaves both the card and the rows.
        store.commit(question: wrong, chosen: "A", correct: true, unsure: false, reason: nil, retry: true,
                     now: day(hour: 20).addingTimeInterval(1))
        let after = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(hour: 21))
        XCTAssertEqual(after.retryCount, 2)
        XCTAssertEqual(after.reviewCount, after.reviewOnlyDueCount + after.retryCount)
        XCTAssertNil(after.reviewBySubject[Subjects.all[0]])
        XCTAssertEqual(after.reviewBySubject.values.reduce(0, +), after.reviewCount)
    }

    func testCountBySubjectSkipsUnknownQuestions() {
        let subjects = ["a": "S1", "b": "S1", "c": "S2"]
        XCTAssertEqual(TodaySummary.countBySubject(["a", "b", "c", "gone"]) { subjects[$0] }, ["S1": 2, "S2": 1])
    }

    // MARK: New-question quotas

    func testRatioModesReserveNewInsideGoalAndRetainReviewBacklog() {
        let due = (0..<30).map { DailyPlanner.DueItem(id: "d\($0)", due: day(-1), subject: "S") }
        let pool = ["S": (0..<30).map { "n\($0)" }]
        func plan(_ mode: NewRatioMode, percent: Int = 25) -> DailyPlanner.Plan {
            DailyPlanner.plan(due: due, unseenBySubject: pool, accuracy: [:], goal: 20, answeredToday: 0,
                              subjectOrder: ["S"], ratioMode: mode, customNewPercent: percent)
        }
        XCTAssertEqual(plan(.normal).newIDs.count, 5)
        XCTAssertEqual(plan(.custom, percent: 50).newIDs.count, 10)
        XCTAssertEqual(plan(.custom, percent: 0).newIDs.count, 0)
        XCTAssertEqual(plan(.custom, percent: 100).newIDs.count, 20)
        XCTAssertTrue(plan(.reviewOnly).newIDs.isEmpty)
        for mode in NewRatioMode.allCases {
            let p = plan(mode)
            XCTAssertEqual(p.dueIDs.count, 30)
            XCTAssertTrue(Set(p.newIDs).isSubset(of: Set(p.queue.prefix(20))))
        }
        XCTAssertEqual(DailyPlanner.newQuota(goal: 5, mode: .normal), 1)
        XCTAssertEqual(DailyPlanner.newQuota(goal: 5, mode: .custom, customPercent: 50), 3)
        let done = DailyPlanner.plan(due: due, unseenBySubject: pool, accuracy: [:], goal: 20, answeredToday: 20,
                                     subjectOrder: ["S"], correctToday: 20, ratioMode: .custom, customNewPercent: 100)
        XCTAssertTrue(done.newIDs.isEmpty)
    }

    func testShortReviewsFillWithNewEmptyNewPoolFillsWithReviewsAndRetryIsDeduplicated() {
        let due = [DailyPlanner.DueItem(id: "due", due: day(-1), subject: "S")]
        let pool = ["S": (0..<30).map { "n\($0)" }]
        let p = DailyPlanner.plan(due: due, unseenBySubject: pool, accuracy: [:], goal: 20, answeredToday: 10,
                                  subjectOrder: ["S"], correctToday: 0, retryIDs: ["due", "retry", "retry"],
                                  ratioMode: .custom, customNewPercent: 0)
        XCTAssertEqual(p.newIDs.count, 18)
        XCTAssertEqual(p.queue.prefix(2), ["due", "retry"])
        XCTAssertEqual(Set(p.queue).count, p.queue.count)
        let reviews = (0..<30).map { DailyPlanner.DueItem(id: "r\($0)", due: day(-1), subject: "S") }
        let empty = DailyPlanner.plan(due: reviews, unseenBySubject: [:], accuracy: [:], goal: 20, answeredToday: 0,
                                      subjectOrder: ["S"], ratioMode: .custom, customNewPercent: 100)
        XCTAssertEqual(empty.queue.count, 30)
        XCTAssertEqual(empty.dueBeforeNew, 20)
        let reviewOnly = DailyPlanner.plan(due: [], unseenBySubject: pool, accuracy: [:], goal: 20, answeredToday: 0,
                                           subjectOrder: ["S"], retryIDs: ["retry"], ratioMode: .reviewOnly)
        XCTAssertEqual(reviewOnly.queue, ["retry"])
    }

    @MainActor
    func testDefaultsAndDailyScopeOnlyNarrowNewIncludingRetryOutsideScope() throws {
        let defaults = UserDefaults(suiteName: "opto.round6.\(UUID())")!
        XCTAssertEqual(NewRatioMode.value(defaults), .normal)
        XCTAssertEqual(NewRatioMode.customPercent(defaults), 25)
        XCTAssertEqual(NewRatioMode.normalizedPercent(-10), 0)
        XCTAssertEqual(NewRatioMode.normalizedPercent(103), 100)
        XCTAssertEqual(NewRatioMode.normalizedPercent(28), 30)
        var scope = PracticeScope.all
        scope.years = YearSelection(mode: .single, from: 115, to: 115)
        ScopeStore.setDaily(scope, defaults: defaults)
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), defaults: defaults,
                               usageSink: { _, _ in })
        let old = q("old", year: 106), fresh = q("fresh"), special = q("special", special: true)
        let bank = QuestionBank(questions: [old, fresh, special])
        for question in [old, special] {
            store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: nil, now: day())
        }
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day()).retryIDs, [old.id])
        defaults.set(NewRatioMode.reviewOnly.rawValue, forKey: SettingsKey.newRatioMode)
        XCTAssertTrue(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day()).plan.newIDs.isEmpty)
        defaults.set(NewRatioMode.custom.rawValue, forKey: SettingsKey.newRatioMode)
        defaults.set(50, forKey: SettingsKey.customNewPercent)
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day()).plan.newIDs, [fresh.id])
    }

    // MARK: Weekly activity and parked records

    func testWeeklyWrongOnlyMockOnlyAndGoalReachedAreDifferentSignals() {
        let attempts = [fact("wrong", day(-2), correct: false), fact("exam", day(-1), exam: true),
                        fact("correct", day()), fact("correct", day().addingTimeInterval(1)),
                        fact("future", day(1))]
        let week = WeeklyGoal.week(attempts: attempts, goal: 1, now: day(hour: 20), calendar: calendar)
        XCTAssertEqual(week.filter(\.studied).count, 3)
        XCTAssertEqual(week.filter(\.goalMet).count, 1)
        XCTAssertEqual(WeeklyGoal.daysStudied(attempts: attempts, goal: 1, now: day(hour: 20), calendar: calendar), 3)
        XCTAssertEqual(week.first { $0.isToday }?.count, 1)
        XCTAssertEqual(week.first { $0.isToday }?.answeredCount, 2)
    }

    @MainActor
    func testParkExcludesAllReviewSurfacesButStillRecordsElsewhereAndUnparkPreservesMemory() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var events: [(String, [String: Any])] = []
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar),
                               usageSink: { events.append(($0, $1)) })
        let question = q("parked"), bank = QuestionBank(questions: [question])
        store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-1))
        let record = try XCTUnwrap(store.record(for: question.id))
        let schedule = record.schedule
        XCTAssertTrue(store.park(questionID: question.id, now: day()))
        XCTAssertTrue(store.park(questionID: question.id, now: day()))
        XCTAssertEqual(record.parkedAt, day())
        XCTAssertEqual(record.schedule, schedule)
        XCTAssertFalse(record.isOpenMistake(using: store.scheduler, at: day()))
        XCTAssertFalse(record.isMastered(using: store.scheduler, at: day()))
        XCTAssertFalse(record.reviewStatus(using: store.scheduler, at: day()).isScheduled)
        XCTAssertTrue(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day()).plan.queue.isEmpty)
        XCTAssertTrue(store.openMistakeIDs(subject: question.subject, bank: bank, includeSpecial: false, now: day()).isEmpty)
        XCTAssertTrue(store.mistakeFocusIDs(subject: question.subject, bank: bank, includeSpecial: false, now: day()).isEmpty)
        XCTAssertEqual(store.mistakeDigest(now: day()).total, 0)
        XCTAssertEqual(store.mistakeCategories(now: day()).parked.ids, [question.id])
        store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: nil, now: day())
        XCTAssertEqual(store.allAttempts().count, 2)
        XCTAssertTrue(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day()).retryIDs.isEmpty)
        let memory = record.schedule
        XCTAssertTrue(store.unpark(questionID: question.id, now: day()))
        XCTAssertTrue(store.unpark(questionID: question.id, now: day()))
        var expected = memory
        expected.due = calendar.startOfDay(for: day(1))
        XCTAssertEqual(record.schedule, expected)
        XCTAssertEqual(record.reviewStatus(using: store.scheduler, at: day()).nextReviewDate, expected.due)
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(1)).plan.dueIDs, [question.id])
        let parkedEvents = events.filter { $0.0 == "park" || $0.0 == "unpark" }
        XCTAssertEqual(parkedEvents.map(\.0), ["park", "unpark"])
        XCTAssertTrue(parkedEvents.allSatisfy { Set($0.1.keys) == ["qid"] && $0.1["qid"] as? String == question.id })
        XCTAssertFalse(store.park(questionID: "missing"))
    }

    @MainActor
    func testUnparkMasteredCardOverridesPreExamRestUntilTomorrowReview() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let scheduler = Scheduler(calendar: calendar, examDate: calendar.startOfDay(for: day(2)))
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let question = q("mastered"), bank = QuestionBank(questions: [question])
        let record = QuestionRecord(questionID: question.id, subject: question.subject, now: day(-30))
        record.schedule = ReviewSchedule(stability: 80, difficulty: 3, reps: 10, lapses: 1,
                                         lastReview: day(-30), due: day(30), dueCorrectCount: 3)
        record.fsrsVersion = StudyReplay.version
        container.mainContext.insert(record)
        XCTAssertTrue(store.park(questionID: question.id, now: day()))
        XCTAssertTrue(PreExamReviewPlanner.plan(records: [record], scheduler: scheduler, now: day()).isEmpty)
        XCTAssertTrue(store.unpark(questionID: question.id, now: day()))
        XCTAssertEqual(record.reviewStatus(using: scheduler, at: day()).nextReviewDate, calendar.startOfDay(for: day(1)))
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(1)).plan.dueIDs, [question.id])
        let preview = store.preview(questionID: question.id, correct: true, unsure: false, now: day(1))
        store.commit(question: question, chosen: "A", correct: true, unsure: false, reason: nil, now: day(1))
        XCTAssertNil(record.resumeDueDate)
        XCTAssertEqual(record.reps, 11)
        XCTAssertEqual(record.reviewStatus(using: scheduler, at: day(1)), preview)
    }

    // MARK: Mistake categories

    func testCategoriesUseLifetimeWrongCountsRecentWindowHistoricalMasteryAndParkedGroup() {
        let scheduler = Scheduler(calendar: calendar)
        var history: [ReviewHistory.Answer] = []
        var state = ReviewSchedule.unseen
        var t = day(-200)
        func add(_ outcome: ReviewOutcome) {
            history.append(.init(questionID: "relapse", timestamp: t, outcome: outcome))
            state = scheduler.next(state, outcome: outcome, at: t)
        }
        add(.wrong)
        for _ in 0..<20 {
            if scheduler.isMastered(state, at: t) { break }
            t = state.due!.addingTimeInterval(9 * 3600)
            add(.correct)
        }
        XCTAssertTrue(scheduler.isMastered(state, at: t))
        t = state.due!.addingTimeInterval(9 * 3600)
        add(.wrong)
        XCTAssertFalse(scheduler.isMastered(state, at: t))
        for offset in [-7, -2, 0] {
            history.append(.init(questionID: "frequent", timestamp: day(offset), outcome: .wrong))
        }
        for index in 0..<3 {
            history.append(.init(questionID: "parked", timestamp: day().addingTimeInterval(Double(index)),
                                 outcome: .wrong, masteredBefore: true))
        }
        history.append(.init(questionID: "old", timestamp: day(-8), outcome: .wrong))
        let scheduled = scheduler.next(.unseen, outcome: .wrong, at: day(-1))
        let records: [MistakeCategories.Record] = [
            .init(questionID: "relapse", schedule: state), .init(questionID: "frequent", schedule: scheduled),
            .init(questionID: "parked", schedule: scheduled, parked: true), .init(questionID: "old", schedule: scheduled),
            .init(questionID: "mastered", schedule: ReviewSchedule(stability: 80, difficulty: 3, reps: 10, lapses: 1,
                                                                   lastReview: day(-30), due: day(30), dueCorrectCount: 3)),
            .init(questionID: "unseen", schedule: .unseen)
        ]
        let result = MistakeCategories.compute(records: records, attempts: history.reversed(), scheduler: scheduler, now: day(hour: 20))
        XCTAssertEqual(result.all.ids, ["frequent", "mastered", "old", "relapse"])
        XCTAssertEqual(result.recent.ids, ["frequent"])
        XCTAssertEqual(result.frequent.ids, ["frequent"])
        XCTAssertEqual(result.relapsed.ids, ["relapse"])
        XCTAssertEqual(result.parked.ids, ["parked"])
        XCTAssertEqual(result[.all].count, 4)
    }

    func testRecentMistakesIncludeSevenDayBoundaryAndExcludeOlderAndFutureAnswers() {
        let now = day(hour: 20), cutoff = day(-7, hour: 20)
        let scheduler = Scheduler(calendar: calendar)
        let state = scheduler.next(.unseen, outcome: .wrong, at: day(-1))
        let records = ["boundary", "older", "future"].map { MistakeCategories.Record(questionID: $0, schedule: state) }
        let attempts: [ReviewHistory.Answer] = [.init(questionID: "boundary", timestamp: cutoff, outcome: .wrong),
                                               .init(questionID: "older", timestamp: cutoff.addingTimeInterval(-1), outcome: .wrong),
                                               .init(questionID: "future", timestamp: day(1), outcome: .wrong)]
        XCTAssertEqual(MistakeCategories.compute(records: records, attempts: attempts, scheduler: scheduler, now: now).recent.ids,
                       ["boundary"])
    }

    // MARK: Study time and focus day

    func testLiveMasterySnapshotWinsWhenUnparkChangedHistoricalDue() {
        let scheduled = Scheduler(calendar: calendar).next(.unseen, outcome: .wrong, at: day(-1))
        let history: [ReviewHistory.Answer] = [
            .init(questionID: "live", timestamp: day(), outcome: .wrong, masteredBefore: true),
            .init(questionID: "notMastered", timestamp: day(), outcome: .wrong, masteredBefore: false)
        ]
        let result = MistakeCategories.compute(records: [.init(questionID: "live", schedule: scheduled),
                                                         .init(questionID: "notMastered", schedule: scheduled)],
                                               attempts: history, scheduler: Scheduler(calendar: calendar), now: day())
        XCTAssertEqual(result.relapsed.ids, ["live"])
    }

    func testStudyTimeGapsInclusiveFiveMinuteLimitMockTimeAndAttemptAccuracy() {
        let t = day()
        let attempts = [fact("a", t, correct: false), fact("a", t.addingTimeInterval(300)),
                        fact("b", t.addingTimeInterval(601)), fact("mock", t.addingTimeInterval(610), exam: true),
                        fact("c", t.addingTimeInterval(620)), fact("d", t.addingTimeInterval(680), correct: false)]
        let summary = StudyTime.compute(attempts: attempts.reversed(), mocks: [.init(date: t, seconds: 120)],
                                        now: day(hour: 20), calendar: calendar)
        XCTAssertEqual(summary.today.minutes, 8) // 300 + 60 gap seconds, plus 120 measured mock seconds.
        XCTAssertEqual(summary.today.answeredCount, 6)
        XCTAssertEqual(summary.today.newAnsweredCount, 5)
        XCTAssertEqual(summary.today.reviewAnsweredCount, 1)
        XCTAssertEqual(summary.today.accuracy, 67)
        XCTAssertNil(StudyTime.compute(attempts: [], now: t, calendar: calendar).today.accuracy)
    }

    func testStudyTimeDoesNotBridgeMidnightAndFocusUsesThirtyLocalDaysWithTimeTieBreak() {
        let midnight = calendar.startOfDay(for: day())
        let attempts = [fact("before", midnight.addingTimeInterval(-10)), fact("after", midnight.addingTimeInterval(10)),
                        fact("old1", day(-30)), fact("old2", day(-30).addingTimeInterval(60)), fact("old3", day(-30).addingTimeInterval(120)),
                        fact("within1", day(-29)), fact("within2", day(-29).addingTimeInterval(60)),
                        fact("tie1", day(-2)), fact("tie2", day(-2).addingTimeInterval(120))]
        let summary = StudyTime.compute(attempts: attempts, now: day(hour: 20), calendar: calendar)
        XCTAssertEqual(summary.today.minutes, 0)
        XCTAssertEqual(summary.mostFocusedDay?.date, calendar.startOfDay(for: day(-2)))
        XCTAssertEqual(summary.mostFocusedDay?.minutes, 2)
        XCTAssertEqual(summary.mostFocusedDay?.answeredCount, 2)
        XCTAssertNil(StudyTime.compute(attempts: [], now: day(), calendar: calendar).mostFocusedDay)
    }

    @MainActor
    func testStudyActivityUsesMockQuestionSecondsOnceAndSplitsTodayAgainstLifetimeHistory() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        let questions = [q("old"), q("fresh"), q("blank")], bank = QuestionBank(questions: [q("old"), q("fresh"), q("blank")])
        store.commit(question: questions[0], chosen: "B", correct: false, unsure: false, reason: nil, now: day(-1))
        let exam = MockExam(subject: Subjects.all[0], mode: .wholePaper, paperCode: "115100", title: "test",
                            questionIDs: questions.map(\.id), now: day())
        exam.answers = ["A", "B", ""]
        exam.seconds = [60, 120, 30, 999] // Ignore out-of-range legacy slots, retain time spent on a blank question.
        container.mainContext.insert(exam)
        store.finish(exam: exam, bank: bank, elapsed: 900, auto: false, now: day().addingTimeInterval(900))
        let activity = store.studyActivity(now: day(hour: 20))
        XCTAssertEqual(activity.today.minutes, 3.5)
        XCTAssertEqual(activity.today.answeredCount, 2)
        XCTAssertEqual(activity.today.newAnsweredCount, 1)
        XCTAssertEqual(activity.today.reviewAnsweredCount, 1)
        XCTAssertEqual(activity.today.accuracy, 50)
        XCTAssertEqual(activity.mostFocusedDay?.answeredCount, 2)
        let today = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(hour: 20))
        XCTAssertEqual(today.correctToday, 0)
        XCTAssertEqual(today.studyMinutesToday, 3.5)
        XCTAssertEqual(today.answeredCountToday, 2)
        XCTAssertEqual(today.newAnsweredToday, 1)
        XCTAssertEqual(today.reviewAnsweredToday, 1)
        XCTAssertEqual(today.todayAccuracy, 50)
    }
}
