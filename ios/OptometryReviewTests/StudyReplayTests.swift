import XCTest
import SwiftData
@testable import OptometryReview

final class StudyReplayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour))!)!
    }
    private struct Answer {
        let offset: Int
        let outcome: ReviewOutcome
        var hour: Int = 9
        var exam: Bool = false
    }

    @MainActor
    func testPopulationPreExamReplayMatchesLiveAndDoesNotPullRemainingCardsForward() throws {
        let scheduler = Scheduler(calendar: calendar, examDate: calendar.startOfDay(for: day(30)))
        let live = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let replay = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: live.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        let questions = (0..<3).map { index in
            Question(id: "preexam-\(index)", code: "115100", year: 115, examKind: "一般", subject: Subjects.all[0],
                     number: index + 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"],
                     originalAnswer: "A", corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
        }
        for q in questions {
            store.commit(question: q, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-60))
            for _ in 0..<12 {
                let record = try XCTUnwrap(store.record(for: q.id))
                if record.isMastered(using: scheduler, at: day(0)) { break }
                let due = try XCTUnwrap(record.dueDate).addingTimeInterval(9 * 3600)
                store.commit(question: q, chosen: "A", correct: true, unsure: false, reason: nil, now: due)
            }
            XCTAssertTrue(try XCTUnwrap(store.record(for: q.id)).isMastered(using: scheduler, at: day(0)))
        }
        let bank = QuestionBank(questions: questions)
        let before = PreExamReviewPlanner.plan(records: store.allRecords(), scheduler: scheduler, now: day(16))
        let previousMasteredState = try XCTUnwrap(store.record(for: questions[0].id)).schedule
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(16)).plan.dueIDs, [questions[0].id])
        store.commit(question: questions[0], chosen: "A", correct: true, unsure: false, reason: nil, now: day(16))
        let after = PreExamReviewPlanner.plan(records: store.allRecords(), scheduler: scheduler, now: day(16, hour: 20))
        XCTAssertEqual(after[questions[0].id], .suppressed)
        for q in questions.dropFirst() { XCTAssertEqual(after[q.id], before[q.id]) }
        XCTAssertTrue(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(16)).plan.dueIDs.isEmpty)
        for q in questions {
            let original = try XCTUnwrap(store.record(for: q.id))
            replay.mainContext.insert(QuestionRecord(questionID: q.id, subject: q.subject, now: original.firstSeen))
        }
        for attempt in store.allAttempts().reversed() {
            replay.mainContext.insert(AttemptRecord(questionID: attempt.questionID, subject: attempt.subject,
                timestamp: attempt.timestamp, chosen: attempt.chosen, correct: attempt.correct,
                reason: attempt.reason, unsure: attempt.unsure, source: attempt.source))
        }
        try replay.mainContext.save()
        try StudyReplay.run(context: replay.mainContext, scheduler: scheduler)
        let target = StudyStore(context: replay.mainContext, scheduler: scheduler, usageSink: { _, _ in })
        for q in questions {
            XCTAssertEqual(target.record(for: q.id)?.schedule, store.record(for: q.id)?.schedule)
        }
        XCTAssertEqual(PreExamReviewPlanner.plan(records: target.allRecords(), scheduler: scheduler, now: day(16)), after)
        // Upgrade the original replay marker too: version one skipped this due mastered review.
        let outdated = try XCTUnwrap(target.record(for: questions[0].id))
        outdated.schedule = previousMasteredState
        outdated.fsrsVersion = 1
        try replay.mainContext.save()
        try StudyReplay.run(context: replay.mainContext, scheduler: scheduler)
        XCTAssertEqual(outdated.schedule, store.record(for: questions[0].id)?.schedule)
        XCTAssertEqual(outdated.fsrsVersion, StudyReplay.version)
    }

    @MainActor
    func testReplayMatchesLiveHistoriesIncludingEarlyAnswersGuessesAndMocks() throws {
        let histories: [[Answer]] = [
            [.init(offset: 0, outcome: .correct), .init(offset: 1, outcome: .correct)],
            [.init(offset: 0, outcome: .wrong), .init(offset: 0, outcome: .correct, hour: 15),
             .init(offset: 1, outcome: .correct), .init(offset: 3, outcome: .correct),
             .init(offset: 4, outcome: .wrong, exam: true), .init(offset: 5, outcome: .unsure)],
            [.init(offset: 0, outcome: .unsure), .init(offset: 0, outcome: .wrong, hour: 12),
             .init(offset: 1, outcome: .correct), .init(offset: 1, outcome: .unsure, hour: 16)],
            [.init(offset: 0, outcome: .wrong), .init(offset: 1, outcome: .correct),
             .init(offset: 3, outcome: .correct), .init(offset: 10, outcome: .correct),
             .init(offset: 35, outcome: .correct), .init(offset: 36, outcome: .wrong)],
            [.init(offset: 0, outcome: .correct, exam: true), .init(offset: 2, outcome: .wrong, exam: true),
             .init(offset: 3, outcome: .correct, exam: true), .init(offset: 3, outcome: .correct, hour: 18)]
        ]
        for examDate in [nil, Optional(calendar.startOfDay(for: day(13)))] {
            let scheduler = Scheduler(calendar: calendar, examDate: examDate)
            for (index, history) in histories.enumerated() {
                let live = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                let replay = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                let store = StudyStore(context: live.mainContext, scheduler: scheduler, usageSink: { _, _ in })
                let q = Question(id: "history-\(index)", code: "115100", year: 115, examKind: "一般",
                                 subject: Subjects.all[0], number: 1, stem: "test",
                                 options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"],
                                 originalAnswer: "A", corrected: false, correctionNote: nil,
                                 allCredit: false, hasFigure: false, needsReview: false)
                let target = QuestionRecord(questionID: q.id, subject: q.subject, now: day(history[0].offset))
                replay.mainContext.insert(target)
                for answer in history {
                    store.commit(question: q, chosen: answer.outcome == .wrong ? "B" : "A",
                                 correct: answer.outcome != .wrong, unsure: answer.outcome == .unsure, reason: nil,
                                 source: answer.exam ? AttemptRecord.examSource : nil,
                                 now: day(answer.offset, hour: answer.hour))
                }
                // Insert out of order and without inverses; replay must use question IDs and timestamp order.
                for answer in history.reversed() {
                    replay.mainContext.insert(AttemptRecord(questionID: q.id, subject: q.subject,
                        timestamp: day(answer.offset, hour: answer.hour), chosen: answer.outcome == .wrong ? "B" : "A",
                        correct: answer.outcome != .wrong, reason: nil, unsure: answer.outcome == .unsure,
                        source: answer.exam ? AttemptRecord.examSource : nil))
                }
                try replay.mainContext.save()
                try StudyReplay.run(context: replay.mainContext, scheduler: scheduler)
                let expected = try XCTUnwrap(store.record(for: q.id))
                XCTAssertEqual(target.schedule, expected.schedule, "history \(index)")
                XCTAssertEqual(target.lastAnswered, expected.lastAnswered)
                XCTAssertEqual(target.fsrsVersion, StudyReplay.version)
                XCTAssertEqual(target.attempts?.count, history.count)
                XCTAssertEqual(target.reviewStatus(using: scheduler, at: day(40)),
                               expected.reviewStatus(using: scheduler, at: day(40)))
                let before = target.schedule
                try StudyReplay.run(context: replay.mainContext, scheduler: scheduler)
                XCTAssertEqual(target.schedule, before)
                XCTAssertFalse(replay.mainContext.hasChanges, "completed replay must not touch rows or save")
            }
        }
    }
}
