import XCTest
import SwiftData
@testable import OptometryReview

/// Third review round: read-only question detail.
@MainActor
final class ReauditRound3Tests: XCTestCase {
    private func q(_ id: String) -> Question {
        Question(id: id, code: "115100", year: 115, examKind: ExamKind.general, subject: Subjects.all[0], number: 1,
                 stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A",
                 corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
    }

    func testViewingQuestionDetailWritesNothing() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext)
        let question = q("x")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        store.commit(question: question, chosen: "B", correct: false, unsure: false, reason: "觀念不懂", now: t0)
        store.commit(question: question, chosen: "A", correct: true, unsure: true, reason: nil, now: t0.addingTimeInterval(86_400))
        store.commit(question: question, chosen: "", correct: false, unsure: false, reason: nil, revealed: true,
                     now: t0.addingTimeInterval(2 * 86_400))
        let record = try XCTUnwrap(store.record(for: "x"))
        let attemptsBefore = store.allAttempts().count
        let scheduleBefore = record.schedule
        let reasonBefore = record.lastReason

        let history = QuestionHistory.load(questionID: "x", store: store)

        XCTAssertEqual(history.entries.map(\.outcome), ["看解答", "答對・猜的", "答錯"])
        XCTAssertEqual(history.entries.last?.reason, "觀念不懂")
        XCTAssertEqual(history.latestReason, reasonBefore)
        XCTAssertEqual(store.allAttempts().count, attemptsBefore)
        XCTAssertEqual(store.record(for: "x")?.schedule, scheduleBefore)
        XCTAssertEqual(store.record(for: "x")?.lastReason, reasonBefore)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(QuestionHistory.load(questionID: "never", store: store), .empty)
        XCTAssertNil(store.record(for: "never"))
    }

    func testQuestionReportEnqueuesOneEvent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID())", isDirectory: true)
            .appendingPathComponent("usage-queue.jsonl")
        let defaults = UserDefaults(suiteName: "opto.report.\(UUID())")!
        let device = UsageDevice(id: "12345678-1234-1234-1234-123456789012", name: "", model: "iPhone15,2",
                                 os: "26.1", app: "1.0 (12)")
        let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-only", fallbackBaseURLs: []),
                           defaults: defaults, queueURL: url, device: device, isTesting: false, isSimulator: false,
                           arguments: [], transport: { _, _ in 500 })
        let question = q("115100_視光學_1")
        XCTAssertFalse(QuestionReport.isReported(question.id, defaults: defaults))

        QuestionReport.submit(question, category: .options, note: "  B 少一個字  ", log: log, defaults: defaults)

        let events = try UsageEventQueue(url: url).events.filter { $0["type"] as? String == "question_report" }
        XCTAssertEqual(events.count, 1)
        let e = try XCTUnwrap(events.first)
        XCTAssertEqual(e["qid"] as? String, question.id)
        XCTAssertEqual(e["subject"] as? String, question.subject)
        XCTAssertEqual(e["category"] as? String, "options")
        XCTAssertEqual(e["note"] as? String, "B 少一個字")
        XCTAssertTrue(QuestionReport.isReported(question.id, defaults: defaults))

        // An empty note is omitted; the note is capped at 300 characters.
        XCTAssertNil(QuestionReport.fields(questionID: "x", subject: "s", category: .other, note: "   ")["note"])
        let long = QuestionReport.fields(questionID: "x", subject: "s", category: .stem, note: String(repeating: "字", count: 400))
        XCTAssertEqual((long["note"] as? String)?.count, 300)
        XCTAssertEqual(QuestionReport.Category.allCases.map(\.rawValue), ["stem", "options", "figure", "answer", "other"])
    }

    func testCustomPracticeSizeStepperBoundsAndPersistence() throws {
        XCTAssertEqual(CustomPracticeChoice.customUpper(matched: 0), 5)
        XCTAssertEqual(CustomPracticeChoice.customUpper(matched: 12), 15)
        XCTAssertEqual(CustomPracticeChoice.customUpper(matched: 30), 30)
        XCTAssertEqual(CustomPracticeChoice.customUpper(matched: 900), 200)
        var choice = CustomPracticeChoice()
        XCTAssertFalse(choice.isCustomSize)
        choice.size = 35
        XCTAssertTrue(choice.isCustomSize)
        XCTAssertEqual(choice.take(12), 12)
        XCTAssertEqual(choice.take(100), 35)
        let defaults = UserDefaults(suiteName: "opto.custom.\(UUID())")!
        ScopeStore.setCustom(choice, defaults: defaults)
        XCTAssertEqual(ScopeStore.custom(defaults).size, 35)
    }
}
