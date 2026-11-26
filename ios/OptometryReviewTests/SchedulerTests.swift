import XCTest
import SwiftData
@testable import OptometryReview

final class SchedulerTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()
    private var scheduler: Scheduler { Scheduler(calendar: calendar) }
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour))!
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }
    private func start(_ offset: Int) -> Date { calendar.startOfDay(for: day(offset)) }
    private func scheduled(stability: Double, lastReview: Date, due: Date, correctCount: Int = 0) -> ReviewSchedule {
        ReviewSchedule(stability: stability, difficulty: 6.4, reps: 4, lapses: 1,
                       lastReview: lastReview, due: due, dueCorrectCount: correctCount)
    }

    func testRatingMappingNeverProducesEasy() {
        XCTAssertEqual(ReviewOutcome(correct: false, unsure: false).rating, .again)
        XCTAssertEqual(ReviewOutcome(correct: false, unsure: true).rating, .again)
        XCTAssertEqual(ReviewOutcome(correct: true, unsure: true).rating, .hard)
        XCTAssertEqual(ReviewOutcome(correct: true, unsure: false).rating, .good)
    }

    func testWrongAndGuessEnterSchedulingAndPlainCorrectIsAConfirmation() {
        let wrong = scheduler.next(.unseen, outcome: .wrong, at: day(0, hour: 23))
        XCTAssertEqual(wrong.stability, 0.212)
        XCTAssertEqual(wrong.difficulty, 6.4133)
        XCTAssertEqual(wrong.reps, 1); XCTAssertEqual(wrong.lapses, 1)
        XCTAssertEqual(wrong.due, start(1)); XCTAssertEqual(wrong.lastReview, day(0, hour: 23))
        let guess = scheduler.next(.unseen, outcome: .unsure, at: day(0))
        XCTAssertEqual(guess.stability, 1.2931)
        XCTAssertEqual(guess.dueCorrectCount, 0); XCTAssertEqual(guess.due, start(1))
        // A1: a first plain-correct answer is a 確認題 rated FSRS Easy (8 days), not a mistake.
        let correct = scheduler.next(.unseen, outcome: .correct, at: day(0))
        XCTAssertEqual(correct.stability, 8.2956)
        XCTAssertEqual(correct.dueCorrectCount, 1); XCTAssertEqual(correct.due, start(8))
        XCTAssertTrue(correct.isConfirmation); XCTAssertFalse(correct.isMistake)
        XCTAssertTrue(wrong.isMistake); XCTAssertTrue(guess.isMistake)
        XCTAssertEqual(scheduler.preview(.unseen, outcome: .correct, at: day(0)).nextReviewDate, start(8))
    }

    func testFourEarlyCorrectAnswersDoNotMasterOrAdvance() {
        let original = scheduler.next(.unseen, outcome: .wrong, at: day(0))
        var state = original
        for _ in 0..<4 { state = scheduler.next(state, outcome: .correct, at: day(0, hour: 20)) }
        XCTAssertEqual(state, original)
        let next = scheduler.next(state, outcome: .correct, at: day(1))
        XCTAssertEqual(next.dueCorrectCount, 1); XCTAssertEqual(next.reps, 2)
        XCTAssertEqual(next.due, start(3))
    }

    func testEarlyWrongAndUnsureApplyFSRSAndResetDueCorrectCount() {
        let state = scheduled(stability: 8, lastReview: day(-1), due: start(7), correctCount: 1)
        for outcome in [ReviewOutcome.wrong, .unsure] {
            let next = scheduler.next(state, outcome: outcome, at: day(0))
            let expected = FSRS().review(.init(stability: 8, difficulty: 6.4), rating: outcome.rating, elapsedDays: 1)
            XCTAssertEqual(next.stability, expected.memory.stability)
            XCTAssertEqual(next.difficulty, expected.memory.difficulty)
            XCTAssertEqual(next.reps, state.reps + 1); XCTAssertEqual(next.dueCorrectCount, 0)
            XCTAssertEqual(next.due, start(expected.intervalDays))
        }
    }

    func testCrossingMidnightStillUsesShortTermFormulaUntilAWholeDayElapses() {
        let lastReview = day(0, hour: 23).addingTimeInterval(59 * 60)
        let state = scheduled(stability: 8, lastReview: lastReview, due: start(7), correctCount: 1)
        let now = day(1, hour: 0).addingTimeInterval(60)
        let next = scheduler.next(state, outcome: .wrong, at: now)
        let expected = FSRS().review(.init(stability: 8, difficulty: 6.4), rating: .again, elapsedDays: 0)
        XCTAssertEqual(next.stability, expected.memory.stability)
        XCTAssertEqual(next.difficulty, expected.memory.difficulty)
        XCTAssertEqual(next.due, start(1 + expected.intervalDays))
    }

    func testMasteryNeedsTwoDueCorrectReviewsAndTwentyOneDayInterval() {
        let mastered = scheduled(stability: 21, lastReview: day(0), due: start(21), correctCount: 2)
        XCTAssertTrue(scheduler.isMastered(mastered, at: day(0)))
        XCTAssertFalse(scheduler.isOpenMistake(mastered, at: day(0)))
        XCTAssertTrue(scheduler.isDue(mastered, on: day(30)))
        var oneCorrect = mastered; oneCorrect.dueCorrectCount = 1
        XCTAssertFalse(scheduler.isMastered(oneCorrect, at: day(0)))
        var short = mastered; short.due = start(20)
        XCTAssertFalse(scheduler.isMastered(short, at: day(0)))
        let reviewed = scheduler.next(mastered, outcome: .correct, at: day(30))
        XCTAssertEqual(reviewed.reps, mastered.reps + 1)
        XCTAssertEqual(reviewed.dueCorrectCount, mastered.dueCorrectCount + 1)
        XCTAssertEqual(reviewed.lastReview, day(30))
        XCTAssertEqual(scheduler.next(mastered, outcome: .correct, at: day(1)), mastered)
        for outcome in [ReviewOutcome.wrong, .unsure] {
            let reopened = scheduler.next(mastered, outcome: outcome, at: day(1))
            XCTAssertEqual(reopened.dueCorrectCount, 0)
            XCTAssertTrue(scheduler.isOpenMistake(reopened, at: day(1)))
        }
    }

    func testExamMasteryBranchReevaluatesWhenExamDateChanges() {
        let state = scheduled(stability: 10, lastReview: day(0), due: start(10), correctCount: 2)
        let near = Scheduler(calendar: calendar, examDate: start(12))
        XCTAssertTrue(near.isMastered(state, at: day(0)))
        XCTAssertFalse(Scheduler(calendar: calendar, examDate: start(20)).isMastered(state, at: day(0)))
        XCTAssertFalse(scheduler.isMastered(state, at: day(0)))
        var onCutoff = state; onCutoff.due = start(9)
        XCTAssertFalse(near.isMastered(onCutoff, at: day(0)), "must fall strictly after exam minus three")
        var reset = state; reset.dueCorrectCount = 0
        XCTAssertFalse(near.isMastered(reset, at: day(0)))
        for outcome in [ReviewOutcome.wrong, .unsure] {
            XCTAssertFalse(near.isMastered(near.next(state, outcome: outcome, at: day(0)), at: day(0)))
        }
    }

    func testExamClampDoesNotChangeFSRSMemoryAndFinalWindowUsesLastReview() {
        let state = scheduled(stability: 30, lastReview: day(-30), due: start(0), correctCount: 0)
        let plain = scheduler.next(state, outcome: .correct, at: day(0))
        let far = Scheduler(calendar: calendar, examDate: start(30))
        let clamped = far.next(state, outcome: .correct, at: day(0))
        XCTAssertEqual(clamped, plain, "exam clamp cannot alter the persisted FSRS state")
        XCTAssertEqual(far.status(clamped, at: day(0)).nextReviewDate, start(27))
        XCTAssertEqual(scheduler.status(clamped, at: day(0)).nextReviewDate, plain.due)
        let final = Scheduler(calendar: calendar, examDate: start(13))
        XCTAssertEqual(final.status(clamped, at: day(0)).nextReviewDate, start(1))
        XCTAssertFalse(final.isDue(clamped, on: day(0)))
        XCTAssertTrue(final.isDue(clamped, on: day(1)))
        XCTAssertEqual(final.preview(state, outcome: .correct, at: day(0)).nextReviewDate, start(1))
    }

    func testDuePlainCorrectCountsUsingEffectiveDueNotRawDate() {
        let final = Scheduler(calendar: calendar, examDate: start(13))
        let state = scheduled(stability: 5, lastReview: day(-2), due: start(7))
        let next = final.next(state, outcome: .correct, at: day(0))
        XCTAssertEqual(next.dueCorrectCount, 1)
        XCTAssertEqual(next.lastReview, day(0))
        XCTAssertEqual(final.status(next, at: day(0)).nextReviewDate, start(1))
    }

    @MainActor
    func testMasteredOverdueQuestionAppearsInTodaysPlanAndAdvancesOnCorrect() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let q = question(answer: ["B"], original: "B")
        let record = QuestionRecord(questionID: q.id, subject: q.subject, now: day(-30))
        record.schedule = scheduled(stability: 21, lastReview: day(-30), due: start(-9), correctCount: 2)
        record.fsrsVersion = StudyReplay.version
        container.mainContext.insert(record)
        let bank = QuestionBank(questions: [q])
        XCTAssertTrue(record.isMastered(using: scheduler, at: day(0)))
        XCTAssertFalse(record.isOpenMistake(using: scheduler, at: day(0)))
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0)).plan.dueIDs, [q.id])
        let reps = record.reps
        store.commit(question: q, chosen: "B", correct: true, unsure: false, reason: nil, now: day(0))
        XCTAssertEqual(record.reps, reps + 1)
        XCTAssertEqual(record.lastReview, day(0))
        XCTAssertTrue(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0)).plan.dueIDs.isEmpty)
    }

    @MainActor
    func testEarlyCorrectMockGradingPreservesScheduleAndEffectiveDate() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let q = question(answer: ["B", "D"], original: "D", corrected: true)
        store.commit(question: q, chosen: "A", correct: false, unsure: false, reason: nil, now: day(0))
        let rec = try XCTUnwrap(store.record(for: q.id))
        let before = rec.schedule, anchor = rec.lastAnswered
        let exam = MockExam(subject: q.subject, mode: .wholePaper, paperCode: q.code, title: "測試",
                            questionIDs: [q.id], now: day(0))
        container.mainContext.insert(exam); exam.answers = ["B"]
        store.finish(exam: exam, bank: QuestionBank(questions: [q]), elapsed: 10, auto: false, now: day(0, hour: 15))
        XCTAssertEqual(rec.schedule, before); XCTAssertEqual(rec.lastAnswered, anchor)
        XCTAssertEqual(rec.attempts?.count, 2)
        XCTAssertEqual(store.preview(questionID: q.id, correct: true, unsure: false, now: day(0)),
                       scheduler.status(before, at: day(0)))
        let final = Scheduler(calendar: calendar, examDate: start(13))
        let finalStore = StudyStore(context: container.mainContext, scheduler: final, usageSink: { _, _ in })
        let effective = final.effectiveDue(before, now: day(0))
        finalStore.commit(question: q, chosen: "D", correct: true, unsure: false, reason: nil, now: day(0, hour: 20))
        XCTAssertEqual(rec.schedule, before)
        XCTAssertEqual(final.effectiveDue(rec.schedule, now: day(0)), effective)
        XCTAssertTrue(final.isDue(rec.schedule, on: day(1)))
    }

    @MainActor
    func testPendingAnswerUsesOptionTapDayAndRevisesOneAttempt() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let q = question(answer: ["B"], original: "B")
        let tappedAt = day(0, hour: 23).addingTimeInterval(59 * 60)
        let pending = store.pendingAnswer(for: q.id, now: tappedAt)
        store.commit(question: q, chosen: "A", correct: false, unsure: false, reason: nil, pending: pending, now: day(1))
        let attemptID = try XCTUnwrap(store.allAttempts().first).persistentModelID
        let original = try XCTUnwrap(store.record(for: q.id)).schedule
        for _ in 0..<2 {
            store.commit(question: q, chosen: "A", correct: false, unsure: false, reason: "算錯", confident: true,
                         pending: pending, now: day(1))
        }
        let attempts = store.allAttempts()
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts.first?.persistentModelID, attemptID)
        XCTAssertEqual(attempts.first?.timestamp, tappedAt); XCTAssertEqual(attempts.first?.confident, true)
        let record = try XCTUnwrap(store.record(for: q.id))
        XCTAssertEqual(record.schedule, original, "confident must not change the rating")
        XCTAssertEqual(record.lastAnswered, tappedAt); XCTAssertEqual(record.dueDate, start(1))
    }

    @MainActor
    func testPendingGuessChangesRecomputeFromOriginalScheduleWithoutExtraAdvancement() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let q = question(answer: ["B"], original: "B")
        let record = QuestionRecord(questionID: q.id, subject: q.subject, now: day(-1))
        let baseline = scheduled(stability: 2, lastReview: day(-1), due: start(0), correctCount: 1)
        record.schedule = baseline; container.mainContext.insert(record)
        let pending = store.pendingAnswer(for: q.id, now: day(0))
        for unsure in [false, true, false, false] {
            store.commit(question: q, chosen: "B", correct: true, unsure: unsure, reason: nil, pending: pending, now: day(1))
            XCTAssertEqual(record.schedule, scheduler.next(baseline, outcome: unsure ? .unsure : .correct, at: day(0)))
        }
        XCTAssertEqual(store.allAttempts().count, 1)
        XCTAssertFalse(try XCTUnwrap(store.allAttempts().first).unsure)
    }

    // MARK: Grading

    private func question(answer: [String], original: String?, corrected: Bool = false, allCredit: Bool = false) -> Question {
        Question(id: "t", code: "115100", year: 115, examKind: "一般", subject: "視光學", number: 40,
                 stem: "stem", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: answer,
                 originalAnswer: original, corrected: corrected, correctionNote: corrected ? "第40題答B或D或BD者均給分" : nil,
                 allCredit: allCredit, hasFigure: false, needsReview: false)
    }

    func testCorrectedMultiAnswerAcceptsAnyListedLetter() {
        let q = question(answer: ["B", "D"], original: "D", corrected: true)
        XCTAssertTrue(Grading.isCorrect(chosen: "B", question: q))
        XCTAssertTrue(Grading.isCorrect(chosen: "D", question: q))
        XCTAssertFalse(Grading.isCorrect(chosen: "A", question: q))
        XCTAssertFalse(Grading.isCorrect(chosen: "C", question: q))
        XCTAssertEqual(q.correctionSummary, "答B或D或BD者均給分")
    }

    func testCorrectedAnswerReplacesOriginal() {
        // 106111 隱形眼鏡學與配鏡學 #50: original D, corrected to A.
        let q = question(answer: ["A"], original: "D", corrected: true)
        XCTAssertTrue(Grading.isCorrect(chosen: "A", question: q))
        XCTAssertFalse(Grading.isCorrect(chosen: "D", question: q))
    }

    func testAllCreditAlwaysCorrect() {
        let q = question(answer: ["A", "B", "C", "D"], original: "B", corrected: true, allCredit: true)
        for letter in Question.letters { XCTAssertTrue(Grading.isCorrect(chosen: letter, question: q)) }
        // Even if the answer list were incomplete, allCredit wins.
        let q2 = question(answer: ["B"], original: "B", corrected: true, allCredit: true)
        XCTAssertTrue(Grading.isCorrect(chosen: "C", question: q2))
        XCTAssertEqual(q2.correctionSummary, "一律給分")
    }

    func testCorrectedAnswerFlowThroughScheduler() {
        let q = question(answer: ["B", "D"], original: "D", corrected: true)
        let outcome = ReviewOutcome(correct: Grading.isCorrect(chosen: "B", question: q), unsure: false)
        let s = scheduled(stability: 1, lastReview: day(-1), due: start(0))
        XCTAssertEqual(scheduler.next(s, outcome: outcome, at: day(0)).dueCorrectCount, 1)
    }
}
