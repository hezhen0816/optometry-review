import XCTest
import SwiftData
@testable import OptometryReview

final class DataSafetyTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-data-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    func testUnversionedStoreOpensWithVersionedSchemaAndKeepsEveryModel() throws {
        let url = try tempFolder().appendingPathComponent("default.store")
        let legacySchema = Schema(SchemaV1.models)
        let config = ModelConfiguration(schema: legacySchema, url: url, cloudKitDatabase: .none)
        do {
            let legacy = try ModelContainer(for: legacySchema, configurations: [config])
            try seedV1(legacy.mainContext)
        }
        let versioned = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
        let context = versioned.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MockExam>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FullMock>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionNote>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIExplanation>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuestionRecord>()).first?.attempts?.count, 1)
    }

    @MainActor
    func testOnDiskV1MigratesToV4AndPreservesAllRowsAndValues() throws {
        let url = try tempFolder().appendingPathComponent("v1.store")
        let schema = Schema(versionedSchema: SchemaV1.self)
        do {
            let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            try seedV1(legacy.mainContext)
            try seedV1(legacy.mainContext, id: "other")
        }
        let container = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
        let context = container.mainContext
        let records = try context.fetch(FetchDescriptor<QuestionRecord>())
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        let exams = try context.fetch(FetchDescriptor<MockExam>())
        let fullMocks = try context.fetch(FetchDescriptor<FullMock>())
        let notes = try context.fetch(FetchDescriptor<QuestionNote>())
        let explanations = try context.fetch(FetchDescriptor<AIExplanation>())
        for count in [records.count, attempts.count, exams.count, fullMocks.count, notes.count, explanations.count] {
            XCTAssertEqual(count, 2)
        }
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        XCTAssertEqual(Set(records.map(\.questionID)), ["q", "other"])
        for record in records {
            XCTAssertEqual(record.subject, Subjects.all[0])
            XCTAssertEqual(record.schedule, Scheduler().next(.unseen, outcome: .wrong, at: now))
            XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
            XCTAssertEqual(record.firstSeen, now); XCTAssertEqual(record.lastAnswered, now)
            XCTAssertEqual(record.lastReason, "算錯"); XCTAssertTrue(record.lastConfident)
            let attempt = try XCTUnwrap(record.attempts?.first)
            XCTAssertEqual(record.attempts?.count, 1)
            XCTAssertEqual(attempt.record?.persistentModelID, record.persistentModelID)
            XCTAssertEqual(attempt.questionID, record.questionID); XCTAssertEqual(attempt.timestamp, now)
            XCTAssertEqual(attempt.chosen, "B"); XCTAssertFalse(attempt.correct)
            XCTAssertEqual(attempt.reason, "算錯"); XCTAssertTrue(attempt.unsure); XCTAssertTrue(attempt.confident)
            XCTAssertEqual(attempt.stageBefore, 0); XCTAssertEqual(attempt.stageAfter, 2)
            XCTAssertEqual(attempt.source, AttemptRecord.examSource)
        }
        for exam in exams {
            XCTAssertEqual(exam.mode, .wholePaper); XCTAssertEqual(exam.answers, ["B"])
            XCTAssertEqual(exam.flags, [true]); XCTAssertEqual(exam.reasons, ["算錯"])
            XCTAssertEqual(exam.seconds, [12.5]); XCTAssertEqual(exam.optionOrders, ["DCBA"])
            XCTAssertEqual(exam.elapsed, 12.5); XCTAssertEqual(exam.score, 2); XCTAssertEqual(exam.correctCount, 1)
            XCTAssertTrue(exam.autoSubmitted)
            XCTAssertEqual(exam.startedAt, now); XCTAssertEqual(exam.finishedAt, now); XCTAssertEqual(exam.submittedAt, now)
            XCTAssertTrue(fullMocks.contains { $0.fullID == exam.fullMockID && $0.code == exam.paperCode })
        }
        for full in fullMocks {
            XCTAssertEqual(full.label, "115 年"); XCTAssertEqual(full.startedAt, now)
            XCTAssertEqual(full.finishedAt, now); XCTAssertEqual(full.breakStartedAt, now)
        }
        for note in notes {
            XCTAssertEqual(note.text, "檢查單位"); XCTAssertTrue(note.bookmarked); XCTAssertEqual(note.updatedAt, now)
        }
        for explanation in explanations {
            XCTAssertEqual(explanation.text, "cached"); XCTAssertEqual(explanation.version, 1)
            XCTAssertEqual(explanation.createdAt, "original"); XCTAssertEqual(explanation.savedAt, now)
            XCTAssertTrue(explanation.reportedWrong)
            XCTAssertEqual(explanation.followups, [AIChatTurn(role: .user, text: "為什麼？")])
        }
    }

    @MainActor
    private func seedV1(_ context: ModelContext, id: String = "q") throws {
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let record = SchemaV1.QuestionRecord(questionID: id, subject: Subjects.all[0], now: now)
        record.stage = 2; record.dueDate = now.addingTimeInterval(86_400)
        record.lastConfident = true; record.lastReason = "算錯"
        context.insert(record)
        let attempt = SchemaV1.AttemptRecord(questionID: id, subject: record.subject, timestamp: now, chosen: "B",
                                             correct: false, reason: "算錯", unsure: true, stageBefore: 0, stageAfter: 2,
                                             source: SchemaV1.AttemptRecord.examSource)
        attempt.confident = true
        context.insert(attempt); attempt.record = record
        let full = SchemaV1.FullMock(code: "115100", label: "115 年", now: now)
        full.finishedAt = now; full.breakStartedAt = now
        context.insert(full)
        let exam = SchemaV1.MockExam(subject: record.subject, mode: .wholePaper, paperCode: full.code, title: full.label,
                                     questionIDs: [id], now: now)
        exam.answers = ["B"]; exam.fullMockID = full.fullID; exam.submittedAt = now; exam.finishedAt = now
        exam.flags = [true]; exam.reasons = ["算錯"]; exam.seconds = [12.5]; exam.optionOrders = ["DCBA"]
        exam.elapsed = 12.5; exam.score = 2; exam.correctCount = 1; exam.autoSubmitted = true
        context.insert(exam)
        let note = SchemaV1.QuestionNote(questionID: id, subject: record.subject, now: now)
        note.text = "檢查單位"; note.bookmarked = true
        context.insert(note)
        let explanation = SchemaV1.AIExplanation(questionID: id, text: "cached", version: 1, createdAt: "original", now: now)
        explanation.followups = [AIChatTurn(role: .user, text: "為什麼？")]; explanation.reportedWrong = true
        context.insert(explanation)
        try context.save()
    }

    @MainActor
    func testOnDiskV2MigratesToV4AndPreservesEveryModelAndReplaysOnlyOnce() throws {
        let url = try tempFolder().appendingPathComponent("v2.store")
        let schema = Schema(versionedSchema: SchemaV2.self)
        do {
            let legacy = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            try seedV2(legacy.mainContext)
            try seedV2(legacy.mainContext, id: "other")
        }
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let expected = Scheduler().next(.unseen, outcome: .wrong, at: now)
        do {
            let container = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
            let context = container.mainContext
            let records = try context.fetch(FetchDescriptor<QuestionRecord>())
            XCTAssertEqual(Set(records.map(\.questionID)), ["q", "other"])
            for record in records {
                XCTAssertEqual(record.schedule, expected)
                XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
                XCTAssertEqual(record.firstSeen, now); XCTAssertEqual(record.lastAnswered, now)
                XCTAssertEqual(record.lastReason, "算錯"); XCTAssertTrue(record.lastConfident)
                let attempt = try XCTUnwrap(record.attempts?.first)
                XCTAssertEqual(record.attempts?.count, 1)
                XCTAssertEqual(attempt.record?.persistentModelID, record.persistentModelID)
                XCTAssertEqual(attempt.stageBefore, 0); XCTAssertEqual(attempt.stageAfter, 2)
                XCTAssertEqual(attempt.source, AttemptRecord.examSource)
                XCTAssertEqual(attempt.timestamp, now); XCTAssertEqual(attempt.chosen, "B")
                XCTAssertTrue(attempt.confident); XCTAssertTrue(attempt.unsure)
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 2)
            let exams = try context.fetch(FetchDescriptor<MockExam>())
            let fulls = try context.fetch(FetchDescriptor<FullMock>())
            let notes = try context.fetch(FetchDescriptor<QuestionNote>())
            let explanations = try context.fetch(FetchDescriptor<AIExplanation>())
            for count in [exams.count, fulls.count, notes.count, explanations.count] { XCTAssertEqual(count, 2) }
            for exam in exams {
                XCTAssertEqual(exam.answers, ["B"]); XCTAssertEqual(exam.seconds, [12.5])
                XCTAssertEqual(exam.optionOrders, ["DCBA"]); XCTAssertEqual(exam.score, 2)
                XCTAssertEqual(exam.finishedAt, now); XCTAssertEqual(exam.submittedAt, now)
                XCTAssertTrue(fulls.contains { $0.fullID == exam.fullMockID })
            }
            XCTAssertTrue(notes.allSatisfy { $0.text == "檢查單位" && $0.bookmarked })
            XCTAssertTrue(explanations.allSatisfy { $0.text == "cached" && $0.reportedWrong })
            try StudyReplay.run(context: context, scheduler: Scheduler())
            XCTAssertFalse(context.hasChanges)
        }
        let reopened = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
        let records = try reopened.mainContext.fetch(FetchDescriptor<QuestionRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.schedule == expected && $0.fsrsVersion == StudyReplay.version })
        XCTAssertFalse(reopened.mainContext.hasChanges)
    }

    @MainActor
    func testOnDiskV3MigratesLightweightToV4KeepsAllModelsRelationshipsAndFSRS() throws {
        let url = try tempFolder().appendingPathComponent("v3.store")
        let schema = Schema(versionedSchema: SchemaV3.self)
        let time = Date(timeIntervalSince1970: 1_000_000.125)
        let schedule = ReviewSchedule(stability: 32, difficulty: 3, reps: 7, lapses: 1,
                                      lastReview: time, due: time.addingTimeInterval(32 * 86_400), dueCorrectCount: 4)
        do {
            let legacy = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = legacy.mainContext
            for id in ["q", "other"] {
                let record = SchemaV3.QuestionRecord(questionID: id, subject: Subjects.all[0], now: time)
                record.schedule = schedule
                record.fsrsVersion = StudyReplay.version
                record.lastReason = "算錯"
                context.insert(record)
                let attempt = SchemaV3.AttemptRecord(questionID: id, subject: record.subject, timestamp: time,
                                                     chosen: "B", correct: false, reason: "算錯", unsure: false,
                                                     source: SchemaV3.AttemptRecord.examSource)
                context.insert(attempt)
                attempt.record = record
                let full = SchemaV3.FullMock(code: id, label: "115 年", now: time)
                full.finishedAt = time
                context.insert(full)
                let exam = SchemaV3.MockExam(subject: record.subject, mode: .wholePaper, paperCode: id,
                                             title: "115 年", questionIDs: [id], now: time)
                exam.answers = ["B"]; exam.seconds = [12.5]; exam.optionOrders = ["DCBA"]
                exam.fullMockID = full.fullID; exam.submittedAt = time; exam.finishedAt = time
                context.insert(exam)
                let note = SchemaV3.QuestionNote(questionID: id, subject: record.subject, now: time)
                note.text = "檢查單位"; note.bookmarked = true
                context.insert(note)
                let explanation = SchemaV3.AIExplanation(questionID: id, text: "cached", version: 1,
                                                       createdAt: "original", now: time)
                explanation.followups = [AIChatTurn(role: .user, text: "why?")]
                context.insert(explanation)
            }
            try context.save()
        }
        do {
            let migrated = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
            let context = migrated.mainContext
            let records = try context.fetch(FetchDescriptor<QuestionRecord>())
            XCTAssertEqual(Set(records.map(\.questionID)), ["q", "other"])
            for record in records {
                XCTAssertEqual(record.schedule, schedule, "current FSRS rows must not be replayed during the lightweight migration")
                XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
                XCTAssertEqual(record.firstSeen, time); XCTAssertEqual(record.lastAnswered, time)
                XCTAssertFalse(record.parked); XCTAssertNil(record.parkedAt); XCTAssertNil(record.resumeDueDate)
                let attempt = try XCTUnwrap(record.attempts?.first)
                XCTAssertEqual(record.attempts?.count, 1)
                XCTAssertEqual(attempt.record?.persistentModelID, record.persistentModelID)
                XCTAssertEqual(attempt.chosen, "B"); XCTAssertEqual(attempt.reason, "算錯")
                XCTAssertEqual(attempt.source, AttemptRecord.examSource)
                XCTAssertFalse(attempt.retry); XCTAssertEqual(attempt.answerOrder, 0)
                XCTAssertNil(attempt.masteredBefore)
            }
            for count in [try context.fetchCount(FetchDescriptor<AttemptRecord>()),
                          try context.fetchCount(FetchDescriptor<MockExam>()),
                          try context.fetchCount(FetchDescriptor<FullMock>()),
                          try context.fetchCount(FetchDescriptor<QuestionNote>()),
                          try context.fetchCount(FetchDescriptor<AIExplanation>())] { XCTAssertEqual(count, 2) }
            let fulls = try context.fetch(FetchDescriptor<FullMock>())
            for exam in try context.fetch(FetchDescriptor<MockExam>()) {
                XCTAssertEqual(exam.seconds, [12.5]); XCTAssertEqual(exam.optionOrders, ["DCBA"])
                XCTAssertTrue(fulls.contains { $0.fullID == exam.fullMockID })
            }
            XCTAssertTrue(try context.fetch(FetchDescriptor<QuestionNote>()).allSatisfy { $0.text == "檢查單位" && $0.bookmarked })
            XCTAssertTrue(try context.fetch(FetchDescriptor<AIExplanation>()).allSatisfy { $0.followups.count == 1 && $0.text == "cached" })
            XCTAssertFalse(context.hasChanges)
        }
        let reopened = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
        XCTAssertTrue(try reopened.mainContext.fetch(FetchDescriptor<QuestionRecord>()).allSatisfy { $0.schedule == schedule && !$0.parked })
    }

    @MainActor
    private func seedV2(_ context: ModelContext, id: String = "q") throws {
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let record = SchemaV2.QuestionRecord(questionID: id, subject: Subjects.all[0], now: now)
        record.stage = 2; record.dueDate = now.addingTimeInterval(86_400)
        record.lastConfident = true; record.lastReason = "算錯"
        context.insert(record)
        let attempt = SchemaV2.AttemptRecord(questionID: id, subject: record.subject, timestamp: now, chosen: "B",
                                             correct: false, reason: "算錯", unsure: true, stageBefore: 0, stageAfter: 2,
                                             source: SchemaV2.AttemptRecord.examSource)
        attempt.confident = true
        context.insert(attempt); attempt.record = record
        let full = SchemaV2.FullMock(code: "115100", label: "115 年", now: now)
        full.finishedAt = now; full.breakStartedAt = now
        context.insert(full)
        let exam = SchemaV2.MockExam(subject: record.subject, mode: .wholePaper, paperCode: full.code, title: full.label,
                                     questionIDs: [id], now: now)
        exam.answers = ["B"]; exam.fullMockID = full.fullID; exam.submittedAt = now; exam.finishedAt = now
        exam.flags = [true]; exam.reasons = ["算錯"]; exam.seconds = [12.5]; exam.optionOrders = ["DCBA"]
        exam.elapsed = 12.5; exam.score = 2; exam.correctCount = 1; exam.autoSubmitted = true
        context.insert(exam)
        let note = SchemaV2.QuestionNote(questionID: id, subject: record.subject, now: now)
        note.text = "檢查單位"; note.bookmarked = true
        context.insert(note)
        let explanation = SchemaV2.AIExplanation(questionID: id, text: "cached", version: 1, createdAt: "original", now: now)
        explanation.followups = [AIChatTurn(role: .user, text: "為什麼？")]; explanation.reportedWrong = true
        context.insert(explanation)
        try context.save()
    }

    @MainActor
    func testDedupeKeepsLatestStateAllAttemptsAndLatestNotesAndCache() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let oldTime = Date(timeIntervalSince1970: 1_000)
        let newTime = oldTime.addingTimeInterval(100)
        let old = QuestionRecord(questionID: "q", subject: Subjects.all[0], now: oldTime)
        old.schedule = ReviewSchedule(stability: 1, difficulty: 6, reps: 1, lapses: 1, lastReview: oldTime, due: oldTime)
        old.lastReason = "算錯"; old.lastConfident = true
        let newest = QuestionRecord(questionID: "q", subject: old.subject, now: newTime)
        newest.schedule = ReviewSchedule(stability: 3, difficulty: 6, reps: 3, lapses: 1,
                                         lastReview: newTime, due: newTime.addingTimeInterval(700), dueCorrectCount: 1)
        let third = QuestionRecord(questionID: "q", subject: old.subject, now: oldTime.addingTimeInterval(50))
        third.lastReason = "粗心"
        let unrelated = QuestionRecord(questionID: "untouched", subject: old.subject, now: oldTime)
        for record in [newest, third, unrelated, old] { context.insert(record) }
        for (i, record) in [old, newest, third].enumerated() {
            let attempt = AttemptRecord(questionID: "q", subject: old.subject, timestamp: record.lastAnswered,
                                        chosen: "B", correct: false, reason: record.lastReason, unsure: false,
                                        stageBefore: 0, stageAfter: i + 1)
            attempt.confident = record.lastConfident
            context.insert(attempt); attempt.record = record
        }
        let oldNote = QuestionNote(questionID: "q", subject: old.subject, now: oldTime)
        oldNote.text = "舊筆記"; oldNote.bookmarked = true
        let newNote = QuestionNote(questionID: "q", subject: old.subject, now: newTime)
        newNote.text = "新筆記" // Latest edit intentionally clears the bookmark.
        context.insert(oldNote); context.insert(newNote)
        let oldCache = AIExplanation(questionID: "q", text: "old", version: 1, createdAt: "", now: oldTime)
        let newCache = AIExplanation(questionID: "q", text: "new", version: 2, createdAt: "", now: newTime)
        newCache.followups = [AIChatTurn(role: .assistant, text: "保留追問")]; newCache.reportedWrong = true
        context.insert(oldCache); context.insert(newCache)
        try context.save()

        // Fetch-or-create selects the same winner even before the startup repair runs.
        let store = StudyStore(context: context, usageSink: { _, _ in })
        XCTAssertEqual(store.record(for: "q")?.persistentModelID, newest.persistentModelID)
        XCTAssertEqual(store.note(for: "q")?.persistentModelID, newNote.persistentModelID)
        XCTAssertEqual(AICacheStore(context: context).explanation(for: "q")?.persistentModelID, newCache.persistentModelID)
        let schedule = newest.schedule
        try StudyDeduplication.run(context: context)
        let keep = try XCTUnwrap(store.record(for: "q"))
        XCTAssertEqual(keep.persistentModelID, newest.persistentModelID)
        XCTAssertEqual(keep.schedule, schedule); XCTAssertEqual(keep.lastAnswered, newTime)
        XCTAssertEqual(keep.firstSeen, oldTime); XCTAssertTrue(keep.lastConfident)
        XCTAssertEqual(keep.lastReason, "粗心")
        XCTAssertEqual(keep.attempts?.count, 3)
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0.record?.persistentModelID == keep.persistentModelID })
        XCTAssertEqual(Set(attempts.compactMap(\.reason)), ["算錯", "粗心"])
        XCTAssertTrue(attempts.contains { $0.confident })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
        XCTAssertEqual(store.record(for: "untouched")?.persistentModelID, unrelated.persistentModelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionNote>()), 1)
        XCTAssertEqual(store.note(for: "q")?.text, "新筆記"); XCTAssertFalse(try XCTUnwrap(store.note(for: "q")).bookmarked)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIExplanation>()), 1)
        XCTAssertEqual(AICacheStore(context: context).explanation(for: "q")?.followups, newCache.followups)
        XCTAssertTrue(try XCTUnwrap(AICacheStore(context: context).explanation(for: "q")).reportedWrong)

        try StudyDeduplication.run(context: context)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(store.record(for: "q")?.persistentModelID, keep.persistentModelID)
        XCTAssertEqual(keep.schedule, schedule); XCTAssertEqual(keep.attempts?.count, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionNote>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIExplanation>()), 1)
    }

    @MainActor
    private func seed(_ context: ModelContext) throws {
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let record = QuestionRecord(questionID: "q", subject: Subjects.all[0], now: now)
        record.schedule = ReviewSchedule(stability: 2, difficulty: 6, reps: 2, lapses: 1,
                                         lastReview: now, due: now.addingTimeInterval(86_400), dueCorrectCount: 1)
        record.lastConfident = true; record.lastReason = "算錯"
        context.insert(record)
        let attempt = AttemptRecord(questionID: "q", subject: record.subject, timestamp: now, chosen: "B",
                                    correct: false, reason: "算錯", unsure: false, stageBefore: 0, stageAfter: 2,
                                    source: AttemptRecord.examSource)
        context.insert(attempt); attempt.record = record
        let full = FullMock(code: "115100", label: "115 年", now: now)
        context.insert(full)
        let exam = MockExam(subject: record.subject, mode: .wholePaper, paperCode: full.code, title: full.label,
                            questionIDs: [record.questionID], now: now)
        exam.answers = ["B"]; exam.fullMockID = full.fullID; exam.submittedAt = now; exam.finishedAt = now
        context.insert(exam)
        let note = QuestionNote(questionID: "q", subject: record.subject, now: now)
        note.text = "檢查單位"; note.bookmarked = true
        context.insert(note)
        context.insert(AIExplanation(questionID: "q", text: "cached", version: 1, createdAt: "", now: now))
        try context.save()
    }

    @MainActor
    func testExportRoundTripsCountsRelationshipsAndChineseWithoutAICache() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        try seed(container.mainContext)
        let now = Date(timeIntervalSince1970: 1_000_000.125)
        let file = try StudyExport.makeFile(context: container.mainContext, now: now)
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("檢查單位"))
        XCTAssertFalse(text.contains("cached")); XCTAssertFalse(text.contains("aiExplanations"))
        XCTAssertTrue(file.lastPathComponent.hasPrefix("驗光錯題本作答紀錄-"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(StudyExport.Document.self, from: data)
        XCTAssertEqual(document.formatVersion, StudyExport.formatVersion)
        XCTAssertEqual(document.exportedAt, ISO8601DateFormatter().string(from: now))
        XCTAssertFalse(document.appVersion.isEmpty)
        XCTAssertEqual(document.questionRecords.count, 1); XCTAssertEqual(document.attemptRecords.count, 1)
        XCTAssertEqual(document.mockExams.count, 1); XCTAssertEqual(document.fullMocks.count, 1)
        XCTAssertEqual(document.questionNotes.count, 1)
        XCTAssertEqual(document.attemptRecords.first?.recordQuestionID, "q")
        XCTAssertEqual(document.mockExams.first?.fullMockID, document.fullMocks.first?.fullID)
        XCTAssertEqual(document.questionRecords.first?.dueDate, now.addingTimeInterval(86_400))
        XCTAssertEqual(document.questionNotes.first?.text, "檢查單位")
        XCTAssertNotEqual(try StudyExport.makeFile(context: container.mainContext, now: now), file)
    }

    @MainActor
    func testThrowingPostOpenRepairKeepsStoreAndRetriesUnsavedMarker() throws {
        let folder = try tempFolder()
        let url = folder.appendingPathComponent("default.store")
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)
        do {
            let original = try StudyDataStore.open(config)
            try seed(original.mainContext)
        }
        let recovery = DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.repair.\(UUID())")!)
        var repairs = 0
        let repair: @MainActor (ModelContext) throws -> Void = { context in
            repairs += 1
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<QuestionRecord>()).first)
            XCTAssertEqual(record.fsrsVersion, 0)
            record.fsrsVersion = StudyReplay.version
            record.lastReason = "unsaved repair"
            throw CocoaError(.fileWriteUnknown)
        }
        for _ in 0..<2 {
            let opened = StudyDataStore.makeContainer(configuration: config, recovery: recovery, repair: repair)
            let context = opened.mainContext
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<QuestionRecord>()).first)
            XCTAssertEqual(record.fsrsVersion, 0)
            XCTAssertEqual(record.lastReason, "算錯")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionNote>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIExplanation>()), 1)
            XCTAssertFalse(context.hasChanges)
        }
        XCTAssertEqual(repairs, 2)
        XCTAssertFalse(recovery.pending)
        XCTAssertNil(recovery.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("StoreBackups").path))
    }

    @MainActor
    func testPendingMemoryNoticeReflectsSuccessfulPersistentReopen() throws {
        let url = try tempFolder().appendingPathComponent("default.store")
        try Data("bad".utf8).write(to: url)
        let defaults = UserDefaults(suiteName: "opto.reopen.\(UUID())")!
        let recovery = DataStoreRecovery(defaults: defaults)
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)
        _ = StudyDataStore.makeContainer(configuration: config, recovery: recovery) { configuration in
            if !configuration.isStoredInMemoryOnly { throw CocoaError(.fileReadCorruptFile) }
            return try StudyDataStore.open(configuration)
        }
        XCTAssertTrue(recovery.pending)
        XCTAssertTrue(recovery.usedInMemoryStore)
        _ = StudyDataStore.makeContainer(configuration: config, recovery: recovery)
        XCTAssertTrue(recovery.pending)
        XCTAssertFalse(recovery.usedInMemoryStore)
        XCTAssertFalse(DataStoreRecovery(defaults: defaults).usedInMemoryStore)
    }

    @MainActor
    func testExplicitMemoryConfigurationDoesNotTriggerBackupRecovery() {
        let recovery = DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.explicit.memory.\(UUID())")!)
        _ = StudyDataStore.makeContainer(configuration: ModelConfiguration(schema: StudyDataStore.schema,
                                                                            isStoredInMemoryOnly: true,
                                                                            cloudKitDatabase: .none), recovery: recovery)
        XCTAssertTrue(recovery.usedInMemoryStore)
        XCTAssertFalse(recovery.pending)
        XCTAssertNil(recovery.backupPath)
    }

    @MainActor
    func testRecoveryMovesAllStoreFilesAndPersistsNotice() throws {
        let folder = try tempFolder()
        let url = folder.appendingPathComponent("default.store")
        let originals = ["", "-wal", "-shm"].map { suffix -> (URL, Data) in
            (URL(fileURLWithPath: url.path + suffix), Data("bad\(suffix)".utf8))
        }
        for (file, data) in originals { try data.write(to: file) }
        let defaults = UserDefaults(suiteName: "opto.recovery.\(UUID())")!
        let recovery = DataStoreRecovery(defaults: defaults)
        var calls = 0
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)
        let container = StudyDataStore.makeContainer(configuration: config, recovery: recovery) { configuration in
            calls += 1
            if calls == 1 { throw CocoaError(.fileReadCorruptFile) }
            return try StudyDataStore.open(configuration)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 0)
        XCTAssertTrue(recovery.pending); XCTAssertTrue(recovery.backupComplete)
        XCTAssertFalse(recovery.usedInMemoryStore)
        let backup = URL(fileURLWithPath: try XCTUnwrap(recovery.backupPath))
        for (file, data) in originals { XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(file.lastPathComponent)), data) }
        XCTAssertTrue(DataStoreRecovery(defaults: defaults).pending)
        recovery.acknowledge()
        XCTAssertFalse(DataStoreRecovery(defaults: defaults).pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    @MainActor
    func testSecondOpenFailureFallsBackToMemory() throws {
        let url = try tempFolder().appendingPathComponent("default.store")
        try Data("bad".utf8).write(to: url)
        let recovery = DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.memory.\(UUID())")!)
        var calls = 0
        let container = StudyDataStore.makeContainer(configuration: ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none),
                                                     recovery: recovery) { configuration in
            calls += 1
            if calls < 3 { throw CocoaError(.fileReadCorruptFile) }
            XCTAssertTrue(configuration.isStoredInMemoryOnly)
            return try StudyDataStore.open(configuration)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(recovery.pending); XCTAssertTrue(recovery.usedInMemoryStore)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 0)
    }

    @MainActor
    func testActualCorruptSQLiteIsBackedUpBeforeFreshOpen() throws {
        let url = try tempFolder().appendingPathComponent("default.store")
        let garbage = Data("Not a SQLite store".utf8)
        try garbage.write(to: url)
        let recovery = DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.corrupt.\(UUID())")!)
        let container = StudyDataStore.makeContainer(configuration: ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none),
                                                     recovery: recovery)
        XCTAssertTrue(recovery.pending); XCTAssertTrue(recovery.backupComplete)
        XCTAssertFalse(recovery.usedInMemoryStore)
        let backup = URL(fileURLWithPath: try XCTUnwrap(recovery.backupPath)).appendingPathComponent("default.store")
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 0)
    }

    @MainActor
    func testBackupFailureKeepsOriginalAndUsesMemory() throws {
        let folder = try tempFolder()
        let url = folder.appendingPathComponent("default.store")
        let garbage = Data("preserve me".utf8)
        try garbage.write(to: url)
        try Data("block folder creation".utf8).write(to: folder.appendingPathComponent("StoreBackups"))
        let recovery = DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.backup.failure.\(UUID())")!)
        var calls = 0
        _ = StudyDataStore.makeContainer(configuration: ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none),
                                         recovery: recovery) { configuration in
            calls += 1
            if calls == 1 { throw CocoaError(.fileReadCorruptFile) }
            XCTAssertTrue(configuration.isStoredInMemoryOnly)
            return try StudyDataStore.open(configuration)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(recovery.backupComplete); XCTAssertTrue(recovery.usedInMemoryStore)
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }
}
