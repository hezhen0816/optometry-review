import XCTest
import SwiftData
@testable import OptometryReview

final class ExamTests: XCTestCase {
    private func q(_ n: Int, answer: [String], allCredit: Bool = false, corrected: Bool = false, subject: String = "視覺光學") -> Question {
        Question(id: "T_\(subject)_\(n)", code: "T", year: 115, examKind: ExamKind.general, subject: subject, number: n,
                 stem: "Q\(n)", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: answer,
                 originalAnswer: answer.first, corrected: corrected, correctionNote: nil, allCredit: allCredit,
                 hasFigure: false, needsReview: false)
    }

    private func paper(_ code: String, year: Int, kind: String = ExamKind.general, subject: String = "視覺光學",
                       note: String? = nil) -> Paper {
        Paper(code: code, year: year, examKind: kind, sessionNote: note, subject: subject, fileCode: "0902",
              paperCode: nil, calculatorAllowed: true, questionIDs: [], hasCorrectedQuestions: false)
    }

    // MARK: Scoring

    func testCorrectedMultiAnswerAcceptsEitherLetter() {
        let qs = [q(1, answer: ["B", "C"], corrected: true), q(2, answer: ["B", "C"], corrected: true),
                  q(3, answer: ["B", "C"], corrected: true)]
        let s = ExamScoring.score(questions: qs, answers: ["B", "C", "D"])
        XCTAssertEqual(s, ExamScore(correct: 2, wrong: 1, unanswered: 0))
        XCTAssertEqual(s.score, 4)
    }

    func testAllCreditScoresAnyAnswerButNotBlank() {
        let qs = [q(1, answer: ["A", "B", "C", "D"], allCredit: true), q(2, answer: ["A", "B", "C", "D"], allCredit: true)]
        let s = ExamScoring.score(questions: qs, answers: ["D", ""])
        XCTAssertEqual(s, ExamScore(correct: 1, wrong: 0, unanswered: 1))
    }

    func testUnansweredScoresZeroAndFullPaperIsOutOf100() {
        let qs = (1...50).map { q($0, answer: ["A"]) }
        var answers = Array(repeating: "A", count: 50)
        answers[0] = ""
        answers[1] = "B"
        let s = ExamScoring.score(questions: qs, answers: answers)
        XCTAssertEqual(s, ExamScore(correct: 48, wrong: 1, unanswered: 1))
        XCTAssertEqual(s.score, 96)
        XCTAssertEqual(ExamScoring.score(questions: qs, answers: Array(repeating: "", count: 50)).score, 0)
    }

    // MARK: Clock

    func testClockAutoSubmitsAtSixtyMinutesIncludingPausedTime() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // 50 minutes used before a pause, resumed at t0.
        XCTAssertEqual(ExamClock.remaining(stored: 3_000, resumedAt: t0, now: t0.addingTimeInterval(120)), 480)
        XCTAssertFalse(ExamClock.shouldAutoSubmit(stored: 3_000, resumedAt: t0, now: t0.addingTimeInterval(599)))
        XCTAssertTrue(ExamClock.shouldAutoSubmit(stored: 3_000, resumedAt: t0, now: t0.addingTimeInterval(600)))
        XCTAssertEqual(ExamClock.remaining(stored: 3_000, resumedAt: t0, now: t0.addingTimeInterval(900)), 0)
        // Paused: wall time does not count.
        XCTAssertFalse(ExamClock.shouldAutoSubmit(stored: 3_000, resumedAt: nil, now: t0.addingTimeInterval(10_000)))
        XCTAssertEqual(ExamClock.format(3_600), "60:00")
        XCTAssertEqual(ExamClock.format(0.2), "00:01")
        XCTAssertEqual(ExamClock.format(0), "00:00")
    }

    // MARK: Paper selection

    func testNextUntakenPaperIsNewestNotTaken() {
        let papers = [paper("113100", year: 113), paper("115100", year: 115), paper("114100", year: 114),
                      paper("106111", year: 106, note: "花東考區補辦"), paper("106110", year: 106)]
        XCTAssertEqual(ExamBuilder.nextUntakenPaper(papers, taken: [])?.code, "115100")
        let taken: Set = ["115100_視覺光學", "114100_視覺光學"]
        XCTAssertEqual(ExamBuilder.nextUntakenPaper(papers, taken: taken)?.code, "113100")
        let allTaken = Set(papers.map(\.id))
        XCTAssertEqual(ExamBuilder.nextUntakenPaper(papers, taken: allTaken)?.code, "115100", "falls back to newest")
        XCTAssertNil(ExamBuilder.nextUntakenPaper([], taken: []))
    }

    func testMistakeFocusPutsOpenMistakesFirstAndTopsUpWithoutDuplicates() {
        let ids = ExamBuilder.mistakeFocus(open: ["m1", "m2"], weak: ["w1", "m2"], fresh: ["f1", "f2", "w1", "f3"], count: 5)
        XCTAssertEqual(ids, ["m1", "m2", "w1", "f1", "f2"])
    }

    func testSessionLabels() {
        let papers = [paper("106110", year: 106), paper("106111", year: 106, note: "花東考區補辦"),
                      paper("109060", year: 109, kind: ExamKind.special), paper("109180", year: 109, kind: ExamKind.special),
                      paper("115100", year: 115)]
        XCTAssertEqual(PaperCatalog.sessions(papers, kind: ExamKind.general).map(\.label), ["115 年", "106 年", "106 年 花東補辦"])
        XCTAssertEqual(PaperCatalog.sessions(papers, kind: ExamKind.special).map(\.label), ["109 年 第二次", "109 年 第一次"])
    }

    // MARK: Pass projection

    func testProjectionPassNeedsAverageSixtyAndNoZero() {
        let base = Dictionary(uniqueKeysWithValues: Subjects.all.map { ($0, 60) })
        XCTAssertEqual(PassProjection.evaluate(latest: base), .pass(average: 60))

        var low = base
        low[Subjects.all[4]] = 58
        XCTAssertEqual(PassProjection.evaluate(latest: low), .fail(average: 59.6, zeroSubjects: []))

        var zero = Dictionary(uniqueKeysWithValues: Subjects.all.map { ($0, 90) })
        zero[Subjects.all[2]] = 0
        // Average 72 but one subject at 0 → fail.
        XCTAssertEqual(PassProjection.evaluate(latest: zero), .fail(average: 72, zeroSubjects: [Subjects.all[2]]))
    }

    func testProjectionListsMissingSubjects() {
        let partial = [Subjects.all[0]: 80, Subjects.all[1]: 70]
        XCTAssertEqual(PassProjection.evaluate(latest: partial), .missing(Array(Subjects.all[2...])))
    }

    func testScoreHistoryLatestPreviousAndSeries() {
        let d = { (n: Double) in Date(timeIntervalSince1970: n * 86_400) }
        let entries = [ScoreHistory.Entry(subject: "A", score: 50, date: d(1)),
                       ScoreHistory.Entry(subject: "B", score: 70, date: d(2)),
                       ScoreHistory.Entry(subject: "A", score: 60, date: d(3))]
        XCTAssertEqual(ScoreHistory.latest(entries), ["A": 60, "B": 70])
        XCTAssertEqual(ScoreHistory.previous(entries), ["A": 50])
        XCTAssertEqual(ScoreHistory.averageSeries(entries).map(\.average), [50, 60, 65])
    }

    // MARK: Mistake book

    @MainActor
    func testResumedFullMockRecordsOldSubmissionWithoutReversingNewerReview() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let submitted = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!
        let practiced = calendar.date(byAdding: .day, value: 1, to: submitted)!
        let completed = calendar.date(byAdding: .day, value: 2, to: submitted)!
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        let questions = Subjects.all.enumerated().map { q($0.offset + 1, answer: ["A"], subject: $0.element) }
        let bank = QuestionBank(questions: questions)
        let full = FullMock(code: "T", label: "test", now: submitted)
        container.mainContext.insert(full)
        for (index, question) in questions.enumerated() {
            let exam = MockExam(subject: question.subject, mode: .wholePaper, paperCode: "T", title: "test",
                                questionIDs: [question.id], now: index == 0 ? submitted : completed)
            exam.fullMockID = full.fullID
            exam.answers = ["B"]
            container.mainContext.insert(exam)
            store.finish(exam: exam, bank: bank, elapsed: 60, auto: false, now: index == 0 ? submitted : completed)
        }
        XCTAssertTrue(store.allAttempts().isEmpty)
        let question = questions[0]
        store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: "算錯", now: practiced)
        let record = try XCTUnwrap(store.record(for: question.id))
        let schedule = record.schedule
        let lastAnswered = record.lastAnswered
        store.completeFullMock(full, bank: bank, now: completed)
        XCTAssertTrue(full.isFinished)
        XCTAssertEqual(record.schedule, schedule)
        XCTAssertEqual(record.lastReview, practiced)
        XCTAssertEqual(record.lapses, 1)
        XCTAssertEqual(record.lastAnswered, lastAnswered)
        XCTAssertEqual(record.lastReason, "算錯")
        let delayed = try XCTUnwrap(store.allAttempts().first { $0.questionID == question.id && $0.source == AttemptRecord.examSource })
        XCTAssertEqual(delayed.timestamp, submitted)
        XCTAssertFalse(delayed.correct)
        XCTAssertEqual(record.attempts?.count, 2)
        XCTAssertEqual(store.allAttempts().count, 6)
        store.completeFullMock(full, bank: bank, now: completed)
        XCTAssertEqual(store.allAttempts().count, 6)
    }

    @MainActor
    func testBackdatedAnswerKeepsMostRecentLastAnsweredEvenWithoutScheduledReview() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(), usageSink: { _, _ in })
        let question = q(1, answer: ["A"])
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let older = newer.addingTimeInterval(-86_400)
        store.commit(question: question, chosen: "A", correct: true, unsure: false, reason: nil, now: newer)
        store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: nil,
                     source: AttemptRecord.examSource, now: older)
        XCTAssertEqual(store.record(for: question.id)?.lastAnswered, newer)
        XCTAssertEqual(store.allAttempts().count, 2)
    }

    @MainActor
    func testFinishedMockFeedsWrongAnswersToScheduler() throws {
        let container = try ModelContainer(for: QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let qs = [q(1, answer: ["A"]), q(2, answer: ["B"]), q(3, answer: ["C"])]
        let bank = QuestionBank(questions: qs)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let store = StudyStore(context: context, scheduler: Scheduler(calendar: cal))
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))!

        let exam = MockExam(subject: "視覺光學", mode: .random, paperCode: nil, title: "隨機混合",
                            questionIDs: qs.map(\.id), now: now)
        context.insert(exam)
        exam.answers = ["A", "D", ""]  // right, wrong, unanswered
        let result = store.finish(exam: exam, bank: bank, elapsed: 1_200, auto: false, now: now)

        XCTAssertEqual(result, ExamScore(correct: 1, wrong: 1, unanswered: 1))
        XCTAssertEqual(exam.score, 2)
        XCTAssertNotNil(exam.finishedAt)

        let wrong = try XCTUnwrap(store.record(for: qs[1].id))
        XCTAssertEqual(wrong.reps, 1)
        XCTAssertEqual(wrong.dueDate, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)))
        XCTAssertTrue(wrong.isOpenMistake)
        XCTAssertEqual((wrong.attempts ?? []).count, 1)
        XCTAssertEqual(wrong.attempts?.first?.chosen, "D")
        XCTAssertEqual(wrong.attempts?.first?.source, AttemptRecord.examSource)
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: now).answeredToday, 0,
                       "mock answers do not count toward the daily goal")

        let right = try XCTUnwrap(store.record(for: qs[0].id))
        XCTAssertFalse(right.isOpenMistake, "a new question answered right stays out of the mistake book")
        XCTAssertNil(store.record(for: qs[2].id), "unanswered questions are not recorded")

        store.setReason("算錯", exam: exam, index: 1)
        XCTAssertEqual(store.record(for: qs[1].id)?.lastReason, "算錯")
        XCTAssertEqual(store.record(for: qs[1].id)?.attempts?.first?.reason, "算錯")
        XCTAssertEqual(store.openMistakeIDs(subject: "視覺光學", bank: bank, includeSpecial: false), [qs[1].id])
    }
}
