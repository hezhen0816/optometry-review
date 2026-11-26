import XCTest
import SwiftData
@testable import OptometryReview

final class PreExamReviewPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return result
    }
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour))!)!
    }
    private func start(_ offset: Int) -> Date { calendar.startOfDay(for: day(offset)) }
    private var scheduler: Scheduler { Scheduler(calendar: calendar, examDate: start(30)) }
    private func item(_ id: String, lastReview: Int = 0, stability: Int = 40) -> PreExamReviewPlanner.Item {
        let state = ReviewSchedule(stability: Double(stability), difficulty: 6, reps: 5, lapses: 1,
                                   lastReview: day(lastReview), due: start(lastReview + stability), dueCorrectCount: 3)
        return .init(questionID: id, atWindowStart: state, current: state, lastAnswer: day(lastReview))
    }
    private func date(_ due: ReviewDue?) -> Date? {
        if case .scheduled(let date)? = due { return date }
        return nil
    }

    func testSpreadIsEvenAcrossAllElevenDaysAndStableWithinTheDay() {
        let items = (0..<58).map { item(String(format: "q%03d", $0), stability: 21 + $0) }
        let plan = PreExamReviewPlanner.plan(items: items, scheduler: scheduler, now: day(16))
        let counts = (16...26).map { offset in plan.values.filter { date($0) == start(offset) }.count }
        XCTAssertEqual(plan.count, items.count)
        XCTAssertEqual(counts.reduce(0, +), items.count)
        XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1)
        XCTAssertEqual(plan, PreExamReviewPlanner.plan(items: Array(items.reversed()), scheduler: scheduler, now: day(16, hour: 23)))
    }

    func testWeakestRetrievabilityFirstWithQuestionIDTieBreak() throws {
        let weak = item("weak", lastReview: -80)
        let strong = item("strong")
        let plan = PreExamReviewPlanner.plan(items: [strong, weak], scheduler: scheduler, now: day(16))
        XCTAssertLessThan(try XCTUnwrap(date(plan["weak"])), try XCTUnwrap(date(plan["strong"])))
        let tie = PreExamReviewPlanner.plan(items: [item("b"), item("a")], scheduler: scheduler, now: day(16))
        XCTAssertLessThan(try XCTUnwrap(date(tie["a"])), try XCTUnwrap(date(tie["b"])))
    }

    func testMasteredCardsAreNotDueInTheLastThreeDaysButOpenMistakesAre() {
        let mastered = item("mastered")
        var open = mastered.current; open.dueCorrectCount = 0
        for offset in 27...29 {
            let plan = PreExamReviewPlanner.plan(items: [mastered], scheduler: scheduler, now: day(offset))
            XCTAssertEqual(plan["mastered"], .suppressed)
            XCTAssertFalse(scheduler.isDue(mastered.current, on: day(offset), reviewDue: .scheduled(start(16))))
            XCTAssertTrue(scheduler.isDue(open, on: day(offset)))
        }
    }

    func testReviewedInWindowIsNotReassignedAndOtherSlotsDoNotCompact() {
        let items = (0..<22).map { item(String(format: "q%02d", $0), stability: 21 + $0) }
        let before = PreExamReviewPlanner.plan(items: items, scheduler: scheduler, now: day(16))
        var after = items
        var reviewed = items[0].current
        reviewed.lastReview = day(16); reviewed.due = start(60); reviewed.stability = 44
        after[0] = .init(questionID: items[0].questionID, atWindowStart: items[0].atWindowStart,
                         current: reviewed, lastAnswer: day(16))
        let plan = PreExamReviewPlanner.plan(items: after, scheduler: scheduler, now: day(16, hour: 20))
        XCTAssertEqual(plan[items[0].questionID], .suppressed)
        for other in items.dropFirst() { XCTAssertEqual(plan[other.questionID], before[other.questionID]) }
    }

    func testExamDateChangeReevaluatesWindowAndCompletedStatus() {
        let original = item("q")
        var reviewed = original.current; reviewed.lastReview = day(16); reviewed.due = start(56)
        let candidate = PreExamReviewPlanner.Item(questionID: "q", atWindowStart: original.atWindowStart,
                                                  current: reviewed, lastAnswer: day(16))
        XCTAssertEqual(PreExamReviewPlanner.plan(items: [candidate], scheduler: scheduler, now: day(17))["q"], .suppressed)
        let later = Scheduler(calendar: calendar, examDate: start(40))
        XCTAssertEqual(date(PreExamReviewPlanner.plan(items: [candidate], scheduler: later, now: day(17))["q"]), start(26))
    }

    func testMasteringMidWindowDoesNotChangeExistingSlots() {
        let cohort = (0..<22).map { item(String(format: "q%02d", $0), stability: 21 + $0) }
        let before = PreExamReviewPlanner.plan(items: cohort, scheduler: scheduler, now: day(17))
        var unmastered = item("new").current
        unmastered.dueCorrectCount = 1
        let newlyMastered = PreExamReviewPlanner.Item(questionID: "new", atWindowStart: unmastered,
                                                     current: item("new").current, lastAnswer: day(17))
        let after = PreExamReviewPlanner.plan(items: cohort + [newlyMastered], scheduler: scheduler, now: day(17))
        XCTAssertEqual(after, before)
        XCTAssertNil(after["new"])
    }

    private func question(_ number: Int) -> Question {
        Question(id: "q\(number)", code: "T", year: 115, examKind: ExamKind.general, subject: Subjects.all[0],
                 number: number, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"],
                 originalAnswer: "A", corrected: false, correctionNote: nil, allCredit: false,
                 hasFigure: false, needsReview: false)
    }

    @MainActor
    func testRecordAttemptsFor250AnswersBuildsOnlyOnePlan() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let questions = (1...250).map { question($0) }
        for q in questions {
            let record = QuestionRecord(questionID: q.id, subject: q.subject, now: day(0))
            record.schedule = item(q.id).current
            record.fsrsVersion = StudyReplay.version
            context.insert(record)
        }
        try context.save()
        let expectedPlan = PreExamReviewPlanner.plan(records: try context.fetch(FetchDescriptor<QuestionRecord>()),
                                                     scheduler: scheduler, now: day(16))
        let before = item("baseline").current
        var builds = 0
        let store = StudyStore(context: context, scheduler: scheduler, usageSink: { _, _ in },
                               preExamPlanDidBuild: { builds += 1 })
        let exam = MockExam(subject: Subjects.all[0], mode: .random, paperCode: nil, title: "batch",
                            questionIDs: questions.map(\.id), now: day(16))
        exam.answers = Array(repeating: "A", count: questions.count)
        context.insert(exam)
        store.recordAttempts(of: exam, questions: questions, at: day(16))
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(store.allAttempts().count, 250)
        for q in questions {
            XCTAssertEqual(store.record(for: q.id)?.schedule,
                           scheduler.next(before, outcome: .correct, at: day(16), reviewDue: expectedPlan[q.id]))
        }
    }

    @MainActor
    func testPreviewsSharePlanAndCommitDayAndExamDateInvalidateIt() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let q = question(1)
        let record = QuestionRecord(questionID: q.id, subject: q.subject, now: day(0))
        record.schedule = item(q.id).current
        container.mainContext.insert(record)
        try container.mainContext.save()
        var builds = 0
        var store = StudyStore(context: container.mainContext, scheduler: scheduler, usageSink: { _, _ in },
                                preExamPlanDidBuild: { builds += 1 })
        _ = store.pendingAnswer(for: q.id, now: day(16))
        for outcome in [ReviewOutcome.wrong, .unsure, .correct] {
            _ = store.preview(questionID: q.id, correct: outcome != .wrong, unsure: outcome == .unsure, now: day(16))
        }
        XCTAssertEqual(builds, 1)
        store.commit(question: q, chosen: "B", correct: false, unsure: false, reason: nil, now: day(16))
        XCTAssertEqual(builds, 1)
        _ = store.preview(questionID: q.id, correct: true, unsure: false, now: day(16))
        XCTAssertEqual(builds, 2)
        _ = store.preview(questionID: q.id, correct: true, unsure: false, now: day(17))
        XCTAssertEqual(builds, 3)
        store.scheduler.examDate = start(40)
        _ = store.preview(questionID: q.id, correct: true, unsure: false, now: day(17))
        XCTAssertEqual(builds, 4)
    }
}
