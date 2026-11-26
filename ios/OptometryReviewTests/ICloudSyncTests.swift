import XCTest
import SwiftData
import CloudKit
@testable import OptometryReview

/// 0.3.0 iCloud sync and A8 import: merge rules, import, debounce, settings sync, first-sync backup.
final class ICloudSyncTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    private func day(_ offset: Int = 0, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour))!)!
    }

    private func q(_ id: String) -> Question {
        Question(id: id, code: "115100", year: 115, examKind: ExamKind.general,
                 subject: Subjects.all[0], number: 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                 answer: ["A"], originalAnswer: "A", corrected: false, correctionNote: nil,
                 allCredit: false, hasFigure: false, needsReview: false)
    }

    @MainActor
    private func memoryContainer() throws -> ModelContainer {
        try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @MainActor
    private func store(_ container: ModelContainer) -> StudyStore {
        StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
    }

    /// One device's card for `id` with one attempt, as SwiftData would have created it before syncing.
    @MainActor
    @discardableResult
    private func deviceCard(_ context: ModelContext, _ id: String, at time: Date, correct: Bool,
                            parked: Bool = false, parkedAt: Date? = nil, resume: Date? = nil) -> QuestionRecord {
        let record = QuestionRecord(questionID: id, subject: Subjects.all[0], now: time)
        record.parked = parked; record.parkedAt = parkedAt; record.resumeDueDate = resume
        record.fsrsVersion = StudyReplay.version
        context.insert(record)
        let attempt = AttemptRecord(questionID: id, subject: record.subject, timestamp: time, chosen: correct ? "A" : "B",
                                    correct: correct, reason: nil, unsure: false)
        attempt.answerOrder = 1
        context.insert(attempt)
        attempt.record = record
        return record
    }

    // MARK: Merge rules

    @MainActor
    func testSameQuestionAnsweredOnTwoDevicesMergesIntoOneCardWithBothAttemptsAndReplayedSchedule() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        deviceCard(context, "q", at: day(0), correct: false)   // iPhone
        deviceCard(context, "q", at: day(1), correct: true)    // iPad, offline
        try context.save()
        CloudSync.merge(container: container)
        let records = try context.fetch(FetchDescriptor<QuestionRecord>())
        XCTAssertEqual(records.count, 1)
        let merged = try XCTUnwrap(records.first)
        XCTAssertEqual(merged.attempts?.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 2)
        XCTAssertEqual(merged.fsrsVersion, StudyReplay.version)
        XCTAssertEqual(merged.firstSeen, day(0))

        // Same schedule as one device answering both in order.
        let single = try memoryContainer()
        let s = store(single)
        s.commit(question: q("q"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        s.commit(question: q("q"), chosen: "A", correct: true, unsure: false, reason: nil, now: day(1))
        let expected = try XCTUnwrap(s.record(for: "q"))
        let replayed = try XCTUnwrap(StudyStore(context: context, scheduler: Scheduler(calendar: calendar)).record(for: "q"))
        XCTAssertEqual(replayed.reps, expected.reps)
        XCTAssertEqual(replayed.lapses, expected.lapses)
        XCTAssertEqual(replayed.lastReview, expected.lastReview)
        XCTAssertEqual(replayed.stability, expected.stability, accuracy: 1e-9)
    }

    @MainActor
    func testMergeTakesParkedStateFromNewestParkedAtEvenWhenAnotherCardWasAnsweredLater() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        // iPhone parks on day 1; the iPad answered on day 2 (newer card) without knowing.
        deviceCard(context, "q", at: day(0), correct: false, parked: true, parkedAt: day(1))
        deviceCard(context, "q", at: day(2), correct: false)
        try context.save()
        CloudSync.merge(container: container)
        let merged = try XCTUnwrap(try context.fetch(FetchDescriptor<QuestionRecord>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 1)
        XCTAssertTrue(merged.parked)
        XCTAssertEqual(merged.parkedAt, day(1))
        XCTAssertNil(merged.resumeDueDate)
        XCTAssertEqual(merged.attempts?.count, 2)
    }

    @MainActor
    func testNewerUnparkOnOtherDeviceUnparksAndKeepsItsResumeDate() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        // Card A (kept: answered last) is parked since day 1; card B was unparked on day 3 with tomorrow's review.
        deviceCard(context, "q", at: day(4), correct: false, parked: true, parkedAt: day(1))
        deviceCard(context, "q", at: day(0), correct: false, parked: false, parkedAt: day(3), resume: day(4, hour: 0))
        try context.save()
        CloudSync.merge(container: container)
        let merged = try XCTUnwrap(try context.fetch(FetchDescriptor<QuestionRecord>()).first)
        XCTAssertFalse(merged.parked)
        XCTAssertEqual(merged.parkedAt, day(3))
        XCTAssertEqual(merged.resumeDueDate, day(4, hour: 0))
    }

    @MainActor
    func testLegacyUnparkWithoutTimeLosesToAPark() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        deviceCard(context, "q", at: day(5), correct: false)                       // never parked, kept card
        deviceCard(context, "q", at: day(0), correct: false, parked: true, parkedAt: day(1))
        try context.save()
        CloudSync.merge(container: container)
        XCTAssertTrue(try XCTUnwrap(try context.fetch(FetchDescriptor<QuestionRecord>()).first).parked)
    }

    @MainActor
    func testUnparkRecordsTheTimeOfTheChange() throws {
        let container = try memoryContainer()
        let s = store(container)
        s.commit(question: q("q"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        XCTAssertTrue(s.park(questionID: "q", now: day(1)))
        XCTAssertTrue(s.unpark(questionID: "q", now: day(2)))
        let record = try XCTUnwrap(s.record(for: "q"))
        XCTAssertFalse(record.parked)
        XCTAssertEqual(record.parkedAt, day(2))
    }

    @MainActor
    func testConcurrentNoteEditsKeepTheNewest() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let phone = QuestionNote(questionID: "q", subject: Subjects.all[0], now: day(0, hour: 10))
        phone.text = "手機上寫的"
        let pad = QuestionNote(questionID: "q", subject: Subjects.all[0], now: day(0, hour: 11))
        pad.text = "iPad 上改的"; pad.bookmarked = true
        context.insert(pad); context.insert(phone)
        try context.save()
        CloudSync.merge(container: container)
        let notes = try context.fetch(FetchDescriptor<QuestionNote>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "iPad 上改的")
        XCTAssertEqual(notes.first?.bookmarked, true)
    }

    @MainActor
    func testOrphanedAttemptsAreReattachedOrGetACardButAIAttemptsNever() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let kept = deviceCard(context, "has-card", at: day(0), correct: false)
        // Another device deleted the card these pointed at (nullify leaves them without a card).
        let orphan = AttemptRecord(questionID: "has-card", subject: kept.subject, timestamp: day(1), chosen: "A",
                                   correct: true, reason: nil, unsure: false)
        let lonely = AttemptRecord(questionID: "no-card", subject: kept.subject, timestamp: day(2), chosen: "B",
                                   correct: false, reason: nil, unsure: false)
        let ai = AttemptRecord(questionID: "ai:calc-1", subject: kept.subject, timestamp: day(2), chosen: "B",
                               correct: false, reason: nil, unsure: false, source: AttemptRecord.aiSource)
        for a in [orphan, lonely, ai] { context.insert(a) }
        try context.save()
        // After an iCloud import: reattach to an existing card, but never invent a card (the real one may follow).
        CloudSync.merge(container: container)
        var records = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<QuestionRecord>()).map { ($0.questionID, $0) })
        XCTAssertEqual(Set(records.keys), ["has-card"])
        XCTAssertEqual(records["has-card"]?.attempts?.count, 2)
        XCTAssertEqual(records["has-card"]?.fsrsVersion, StudyReplay.version)
        // At app open, old orphans get a repair card; recent ones still wait.
        try StudyDeduplication.run(context: context, repairOrphans: true, now: day(2).addingTimeInterval(60))
        XCTAssertNil(try context.fetch(FetchDescriptor<QuestionRecord>()).first { $0.questionID == "no-card" })
        try StudyDeduplication.run(context: context, repairOrphans: true, now: day(3))
        try StudyReplay.run(context: context, scheduler: Scheduler(calendar: calendar))
        records = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<QuestionRecord>()).map { ($0.questionID, $0) })
        XCTAssertEqual(Set(records.keys), ["has-card", "no-card"])
        XCTAssertEqual(records["no-card"]?.attempts?.count, 1)
        XCTAssertEqual(records["no-card"]?.createdByRepair, true)
        XCTAssertTrue(try XCTUnwrap(records["no-card"]).schedule.isScheduled)
        XCTAssertNil(ai.record)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 4)
    }

    @MainActor
    func testDeletingADuplicateCardNeverDeletesItsAttempts() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let card = deviceCard(context, "q", at: day(0), correct: false)
        try context.save()
        // What an iCloud import does when the other device merged this card away.
        context.delete(card)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
        try StudyDeduplication.run(context: context, repairOrphans: true, now: day(1))
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuestionRecord>()).first?.attempts?.count, 1)
    }

    @MainActor
    func testARealCardAlwaysBeatsARepairCard() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let repair = deviceCard(context, "q", at: day(5), correct: false)
        repair.createdByRepair = true
        let real = deviceCard(context, "q", at: day(0), correct: false, parked: true, parkedAt: day(1))
        try context.save()
        CloudSync.merge(container: container)
        let merged = try XCTUnwrap(try context.fetch(FetchDescriptor<QuestionRecord>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 1)
        XCTAssertEqual(merged.cardID, real.cardID)
        XCTAssertFalse(merged.createdByRepair)
        XCTAssertEqual(merged.attempts?.count, 2)
    }

    /// The same two cards as two devices see them: this device has its own card's times to the sub-millisecond,
    /// the other received it through CloudKit cut to the millisecond. Both must keep the same card.
    @MainActor
    func testBothDevicesKeepTheSameCardWhenCloudKitCutTimesToMilliseconds() throws {
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!
        func device(subMillisecond: Bool) throws -> (ModelContainer, UUID?) {
            let container = try memoryContainer()
            let context = container.mainContext
            let mine = deviceCard(context, "q", at: day(0).addingTimeInterval(subMillisecond ? 0.000_4 : 0), correct: false)
            mine.cardID = high
            let theirs = deviceCard(context, "q", at: day(0), correct: true)
            theirs.cardID = low
            try context.save()
            CloudSync.merge(container: container)
            return (container, try context.fetch(FetchDescriptor<QuestionRecord>()).first?.cardID)
        }
        let (phone, phoneKeeper) = try device(subMillisecond: true)
        let (pad, padKeeper) = try device(subMillisecond: false)
        XCTAssertEqual(phoneKeeper, low)
        XCTAssertEqual(padKeeper, low)
        XCTAssertEqual(try phone.mainContext.fetchCount(FetchDescriptor<AttemptRecord>()), 2)
        XCTAssertEqual(try pad.mainContext.fetchCount(FetchDescriptor<AttemptRecord>()), 2)
    }

    @MainActor
    func testDuplicateAttemptsAndExamsCollapseToTheSameSurvivorOnBothDevices() throws {
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let high = UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000002")!
        let examID = UUID()
        func device(subMillisecond: Bool) throws -> ModelContainer {
            let container = try memoryContainer()
            let context = container.mainContext
            let card = deviceCard(context, "q", at: day(0).addingTimeInterval(subMillisecond ? 0.000_7 : 0), correct: false)
            card.attempts?.first?.attemptID = high
            // The same answer again, e.g. imported from a file while iCloud was restoring it.
            let copy = AttemptRecord(questionID: "q", subject: card.subject, timestamp: day(0), chosen: "B",
                                     correct: false, reason: nil, unsure: false)
            copy.answerOrder = 1; copy.attemptID = low
            context.insert(copy)
            for id in [high, low] {
                let exam = MockExam(subject: card.subject, mode: .wholePaper, paperCode: nil, title: "t",
                                    questionIDs: ["q"], now: day(0))
                exam.examID = examID; exam.syncID = id
                context.insert(exam)
            }
            // A different answer of the same question stays.
            let later = AttemptRecord(questionID: "q", subject: card.subject, timestamp: day(0).addingTimeInterval(0.005),
                                      chosen: "B", correct: false, reason: nil, unsure: false)
            later.answerOrder = 1
            context.insert(later)
            try context.save()
            CloudSync.merge(container: container)
            return container
        }
        for container in [try device(subMillisecond: true), try device(subMillisecond: false)] {
            let attempts = try container.mainContext.fetch(FetchDescriptor<AttemptRecord>())
            XCTAssertEqual(attempts.count, 2)
            XCTAssertTrue(attempts.contains { $0.attemptID == low })
            XCTAssertFalse(attempts.contains { $0.attemptID == high })
            XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<MockExam>()).map(\.syncID), [low])
        }
    }

    @MainActor
    func testResumeDateSurvivesWhenNoCopyWasEverParked() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        deviceCard(context, "q", at: day(3), correct: false)
        deviceCard(context, "q", at: day(0), correct: false, resume: day(4, hour: 0))
        try context.save()
        CloudSync.merge(container: container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<QuestionRecord>()).first?.resumeDueDate, day(4, hour: 0))
    }

    @MainActor
    func testMergeOnCleanStoreChangesNothing() throws {
        let container = try memoryContainer()
        let s = store(container)
        s.commit(question: q("q"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        CloudSync.merge(container: container)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 1)
    }

    // MARK: Debounced merge trigger

    @MainActor
    func testDebouncedRunnerCoalescesBurstsIntoOneRun() async throws {
        var runs = 0
        let runner = DebouncedRunner(delay: 0.05) { runs += 1 }
        for _ in 0..<5 { runner.trigger() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runs, 1)
        runner.trigger()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runs, 2)
    }

    @MainActor
    func testDebouncedRunnerNeverRunsInsideItself() async throws {
        var depth = 0, maxDepth = 0, runs = 0
        var runner: DebouncedRunner!
        runner = DebouncedRunner(delay: 0.02) {
            depth += 1; maxDepth = max(maxDepth, depth); runs += 1
            if runs == 1 { runner.fire() }   // e.g. a save inside the merge posting another import
            depth -= 1
        }
        runner.fire()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(maxDepth, 1)
        XCTAssertEqual(runs, 2, "a trigger during a run is run once afterwards")
    }

    @MainActor
    func testOnlySuccessfulImportsTriggerTheMerge() async throws {
        var runs = 0
        let sync = CloudSync()
        sync.merger = DebouncedRunner(delay: 0.02) { runs += 1 }
        let id = UUID()
        sync.handle(id, type: .import, finished: false, succeeded: false, error: nil)
        sync.handle(id, type: .import, finished: true, succeeded: false, error: CKError(.networkUnavailable))
        sync.handle(UUID(), type: .export, finished: true, succeeded: true, error: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(runs, 0)
        sync.handle(UUID(), type: .import, finished: true, succeeded: true, error: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(runs, 1)
    }

    func testStatusMapping() {
        XCTAssertEqual(CloudSync.status(enabled: false, account: .available, inProgress: false, error: nil), .unavailable)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .noAccount, inProgress: true, error: nil), .noAccount)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: true, error: nil), .syncing)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false, error: nil), .synced)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false,
                                        error: CKError(.quotaExceeded)), .quotaExceeded)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["x": CKError(.quotaExceeded)]])
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false, error: partial), .quotaExceeded)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false,
                                        error: CKError(.networkUnavailable)), .offline)
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false,
                                        error: CKError(.notAuthenticated)), .noAccount)
        // Transient errors are retried by CloudKit: still syncing, not an alarm.
        XCTAssertEqual(CloudSync.status(enabled: true, account: .available, inProgress: false,
                                        error: CKError(.requestRateLimited)), .synced)
        XCTAssertEqual(CloudSync.Status.synced.title, "已同步")
        XCTAssertEqual(CloudSync.Status.syncing.title, "同步中")
        XCTAssertEqual(CloudSync.Status.noAccount.title, "未登入 iCloud")
        XCTAssertEqual(CloudSync.Status.quotaExceeded.title, "iCloud 空間不足")
    }

    // MARK: Import (A8)

    @MainActor
    private func exportData(_ container: ModelContainer) throws -> Data {
        let url = try StudyExport.makeFile(context: container.mainContext, now: day(10),
                                           scheduler: Scheduler(calendar: calendar), logUsage: false)
        return try Data(contentsOf: url)
    }

    @MainActor
    private func seededSource() throws -> ModelContainer {
        let container = try memoryContainer()
        let s = store(container)
        s.commit(question: q("a"), chosen: "B", correct: false, unsure: false, reason: "算錯", now: day(0))
        s.commit(question: q("a"), chosen: "A", correct: true, unsure: false, reason: nil, now: day(2))
        s.commit(question: q("b"), chosen: "C", correct: false, unsure: false, reason: nil, now: day(1))
        XCTAssertTrue(s.park(questionID: "b", now: day(3)))
        s.setNote("單位換算", question: q("a"), now: day(4))
        s.setBookmark(true, question: q("c"), now: day(4))
        let exam = MockExam(subject: Subjects.all[0], mode: .wholePaper, paperCode: "115100", title: "115 年",
                            questionIDs: ["a"], now: day(5))
        exam.answers = ["A"]; exam.finishedAt = day(5)
        container.mainContext.insert(exam)
        try container.mainContext.save()
        return container
    }

    @MainActor
    func testImportIntoEmptyStoreRestoresEverythingAndDoubleImportAddsNothing() throws {
        let source = try seededSource()
        let data = try exportData(source)
        let target = try memoryContainer()
        let context = target.mainContext

        let preview = try StudyImport.preview(data: data, context: context)
        XCTAssertEqual(preview.summary.attempts, 3)
        XCTAssertEqual(preview.summary.questions, 2)
        XCTAssertEqual(preview.summary.notes, 2)
        XCTAssertEqual(preview.summary.exams, 1)
        XCTAssertEqual(preview.summary.parked, 1)
        XCTAssertFalse(context.hasChanges, "preview never writes")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 0)

        let applied = try StudyImport.apply(preview.document, context: context, scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(applied, preview.summary)
        let t = store(target), s = store(source)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
        for id in ["a", "b"] {
            let got = try XCTUnwrap(t.record(for: id)), want = try XCTUnwrap(s.record(for: id))
            XCTAssertEqual(got.reps, want.reps, id); XCTAssertEqual(got.lapses, want.lapses, id)
            XCTAssertEqual(got.parked, want.parked, id)
            XCTAssertEqual(got.attempts?.count, want.attempts?.count, id)
            XCTAssertEqual(got.fsrsVersion, StudyReplay.version, id)
        }
        XCTAssertTrue(try XCTUnwrap(t.record(for: "b")).parked)
        XCTAssertEqual(t.note(for: "a")?.text, "單位換算")
        XCTAssertEqual(t.note(for: "c")?.bookmarked, true)
        XCTAssertEqual(t.finishedExams().count, 1)
        let answerOrders = try context.fetch(FetchDescriptor<AttemptRecord>()).filter { $0.questionID == "a" }.map(\.answerOrder)
        XCTAssertEqual(Set(answerOrders), [1, 2])

        // Second import of the same file: nothing new, nothing duplicated.
        let again = try StudyImport.preview(data: data, context: context)
        XCTAssertTrue(again.summary.isEmpty, "\(again.summary)")
        try StudyImport.apply(again.document, context: context, scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuestionNote>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MockExam>()), 1)
    }

    @MainActor
    func testImportMergesWithExistingDataAsAUnion() throws {
        let source = try seededSource()
        let data = try exportData(source)
        let target = try memoryContainer()
        let t = store(target)
        // The target answered "a" once more later and edited its note after the export.
        t.commit(question: q("a"), chosen: "A", correct: true, unsure: false, reason: nil, now: day(6))
        t.setNote("我自己的新筆記", question: q("a"), now: day(7))
        let summary = try StudyImport.apply(try StudyImport.decode(data), context: target.mainContext,
                                            scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(summary.attempts, 3)
        XCTAssertEqual(summary.notes, 1, "only the bookmark of c; a's newer local note stays")
        XCTAssertEqual(t.note(for: "a")?.text, "我自己的新筆記")
        XCTAssertEqual(try XCTUnwrap(t.record(for: "a")).attempts?.count, 3)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 2)
    }

    @MainActor
    func testVersion2FileWithoutAnswerOrderMatchesExistingAttempts() throws {
        let source = try seededSource()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try exportData(source)) as? [String: Any])
        json["formatVersion"] = 2
        json["attemptRecords"] = (json["attemptRecords"] as? [[String: Any]])?.map { a in
            var a = a
            for key in ["answerOrder", "retry", "masteredBefore"] { a.removeValue(forKey: key) }
            return a
        }
        json["questionRecords"] = (json["questionRecords"] as? [[String: Any]])?.map { r in
            var r = r
            for key in ["parked", "parkedAt", "resumeDueDate"] { r.removeValue(forKey: key) }
            return r
        }
        let v2 = try JSONSerialization.data(withJSONObject: json)
        let preview = try StudyImport.preview(data: v2, context: source.mainContext)
        XCTAssertTrue(preview.summary.isEmpty, "\(preview.summary)")
        let empty = try memoryContainer()
        XCTAssertEqual(try StudyImport.preview(data: v2, context: empty.mainContext).summary.attempts, 3)
    }

    @MainActor
    func testImportRejectsFilesThatAreNotValidExports() throws {
        let container = try memoryContainer()   // keep the container alive while its context is used
        let context = container.mainContext
        func failure(_ data: Data) -> StudyImport.Failure? {
            do { _ = try StudyImport.preview(data: data, context: context); return nil }
            catch { return error as? StudyImport.Failure }
        }
        XCTAssertEqual(failure(Data("not json".utf8)), .notExport)
        XCTAssertEqual(failure(Data(#"{"hello": 1}"#.utf8)), .notExport)
        XCTAssertEqual(failure(Data(#"{"formatVersion": 99}"#.utf8)), .newerVersion)
        XCTAssertEqual(failure(Data(#"{"formatVersion": 1}"#.utf8)), .notExport)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try exportData(try seededSource())) as? [String: Any])
        var attempts = try XCTUnwrap(json["attemptRecords"] as? [[String: Any]])
        attempts[0]["questionID"] = ""
        json["attemptRecords"] = attempts
        XCTAssertEqual(failure(try JSONSerialization.data(withJSONObject: json)), .invalidContent)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 0)
    }

    @MainActor
    func testImportedAIAttemptsGetNoCard() throws {
        let source = try memoryContainer()
        let ai = AttemptRecord(questionID: "ai:calc-1", subject: Subjects.all[0], timestamp: day(0), chosen: "A",
                               correct: true, reason: nil, unsure: false, source: AttemptRecord.aiSource)
        source.mainContext.insert(ai)
        try source.mainContext.save()
        let target = try memoryContainer()
        let summary = try StudyImport.apply(try StudyImport.decode(try exportData(source)), context: target.mainContext,
                                            scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(summary.attempts, 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<QuestionRecord>()), 0)
    }

    // MARK: Settings sync

    private final class FakeKVS: UbiquitousKeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() -> Bool { true }
    }

    private func suite() -> UserDefaults {
        let name = "opto.settingsSync.\(UUID())"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @MainActor
    func testSettingsSyncUploadsLocalValuesAndTakesNewerRemoteValues() {
        let kvs = FakeKVS()
        let phone = suite()
        phone.set(day(100).timeIntervalSince1970, forKey: SettingsKey.examDate)
        phone.set(30, forKey: SettingsKey.dailyGoal)
        var clock = day(0)
        let phoneSync = SettingsSync(defaults: phone, store: kvs, now: { clock })
        phoneSync.reconcile()
        XCTAssertEqual((kvs.values["settings.dailyGoal"] as? [String: Any])?["value"] as? Int, 30)

        // A new iPad takes both values on first launch.
        let pad = suite()
        let padSync = SettingsSync(defaults: pad, store: kvs, now: { clock })
        padSync.reconcile()
        XCTAssertEqual(pad.integer(forKey: SettingsKey.dailyGoal), 30)
        XCTAssertEqual(pad.double(forKey: SettingsKey.examDate), day(100).timeIntervalSince1970)

        // iPad changes the goal later: last write wins on the phone too.
        clock = day(1)
        pad.set(40, forKey: SettingsKey.dailyGoal)
        padSync.localChanged(key: SettingsKey.dailyGoal)
        phoneSync.remoteChanged(keys: ["settings.dailyGoal"])
        XCTAssertEqual(phone.integer(forKey: SettingsKey.dailyGoal), 40)

        // An older remote value never overwrites a newer local one.
        clock = day(2)
        phone.set(0, forKey: SettingsKey.examDate)      // phone clears the exam date
        phoneSync.localChanged(key: SettingsKey.examDate)
        kvs.values["settings.examDate"] = ["value": day(200).timeIntervalSince1970, "at": day(1).timeIntervalSince1970]
        phoneSync.remoteChanged(keys: nil)
        XCTAssertEqual(phone.double(forKey: SettingsKey.examDate), 0)
        // Out-of-range values are ignored.
        kvs.values["settings.dailyGoal"] = ["value": 9999, "at": day(9).timeIntervalSince1970]
        phoneSync.remoteChanged(keys: nil)
        XCTAssertEqual(phone.integer(forKey: SettingsKey.dailyGoal), 40)
    }

    @MainActor
    func testSettingsSyncNoticesLocalChangesThroughUserDefaults() {
        let kvs = FakeKVS()
        let defaults = suite()
        let sync = SettingsSync(defaults: defaults, store: kvs, now: { self.day(0) })
        sync.start()
        defer { sync.stop() }
        defaults.set(25, forKey: SettingsKey.dailyGoal)
        XCTAssertEqual((kvs.values["settings.dailyGoal"] as? [String: Any])?["value"] as? Int, 25)
        // Applying a remote value does not echo it back with a new time.
        kvs.values["settings.dailyGoal"] = ["value": 50, "at": day(5).timeIntervalSince1970]
        sync.remoteChanged(keys: ["settings.dailyGoal"])
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.dailyGoal), 50)
        XCTAssertEqual((kvs.values["settings.dailyGoal"] as? [String: Any])?["at"] as? Double, day(5).timeIntervalSince1970)
    }

    @MainActor
    func testSettingsSyncCarriesPracticeScopeAndIgnoresInvalidRemoteValues() {
        let kvs = FakeKVS()
        let phone = suite(), pad = suite()
        let phoneSync = SettingsSync(defaults: phone, store: kvs, now: { self.day(0) })
        let padSync = SettingsSync(defaults: pad, store: kvs, now: { self.day(0) })
        phoneSync.start(); padSync.start()
        defer { phoneSync.stop(); padSync.stop() }

        // A dotted key is noticed through the change notification and pushed.
        var scope = PracticeScope.all
        scope.years = YearSelection(mode: .single, from: 115, to: 115)
        ScopeStore.setDaily(scope, defaults: phone)
        XCTAssertNotNil((kvs.values["settings.scope.daily"] as? [String: Any])?["value"] as? String)

        // The iPad takes it, and applying does not echo back with a new time.
        let at = (kvs.values["settings.scope.daily"] as? [String: Any])?["at"] as? Double
        padSync.remoteChanged(keys: ["settings.scope.daily"])
        XCTAssertEqual(ScopeStore.daily(pad), scope)
        XCTAssertEqual((kvs.values["settings.scope.daily"] as? [String: Any])?["at"] as? Double, at)

        // Plain keys: 特考 is a Bool but not a tip; ratio mode and percent travel too.
        pad.set(true, forKey: SettingsKey.includeSpecial)
        pad.set(NewRatioMode.reviewOnly.rawValue, forKey: SettingsKey.newRatioMode)
        pad.set(40, forKey: SettingsKey.customNewPercent)
        phoneSync.remoteChanged(keys: nil)
        XCTAssertTrue(phone.bool(forKey: SettingsKey.includeSpecial))
        XCTAssertEqual(phone.string(forKey: SettingsKey.newRatioMode), NewRatioMode.reviewOnly.rawValue)
        XCTAssertEqual(phone.integer(forKey: SettingsKey.customNewPercent), 40)
        for tip in SettingsKey.allTips { XCTAssertNil(kvs.values["settings." + tip]) }

        // Invalid remote values are ignored.
        let later = day(9).timeIntervalSince1970
        kvs.values["settings.scope.daily"] = ["value": "garbage", "at": later]
        kvs.values["settings.newRatioMode"] = ["value": "nope", "at": later]
        kvs.values["settings.customNewPercent"] = ["value": 500, "at": later]
        phoneSync.remoteChanged(keys: nil)
        XCTAssertEqual(ScopeStore.daily(phone), scope)
        XCTAssertEqual(phone.string(forKey: SettingsKey.newRatioMode), NewRatioMode.reviewOnly.rawValue)
        XCTAssertEqual(phone.integer(forKey: SettingsKey.customNewPercent), 40)
    }

    @MainActor
    func testSettingsSyncReconcileNewerWinsForScope() {
        let kvs = FakeKVS()
        var older = PracticeScope.all; older.subject = Subjects.all[0]
        var newer = PracticeScope.all; newer.years = YearSelection(mode: .single, from: 114, to: 114)
        kvs.values["settings.scope.daily"] = ["value": ScopeStore.encode(newer), "at": day(5).timeIntervalSince1970]
        let d = suite()
        ScopeStore.setDaily(older, defaults: d)
        d.set(day(1).timeIntervalSince1970, forKey: SettingsSync.stampKey(ScopeStore.dailyKey))
        SettingsSync(defaults: d, store: kvs, now: { self.day(6) }).reconcile()
        XCTAssertEqual(ScopeStore.daily(d), newer)

        // A newer local value is uploaded instead.
        let e = suite()
        ScopeStore.setDaily(older, defaults: e)
        e.set(day(8).timeIntervalSince1970, forKey: SettingsSync.stampKey(ScopeStore.dailyKey))
        SettingsSync(defaults: e, store: kvs, now: { self.day(9) }).reconcile()
        XCTAssertEqual(ScopeStore.daily(e), older)
        XCTAssertEqual(ScopeStore.decode((kvs.values["settings.scope.daily"] as? [String: Any])?["value"] as? String), older)
    }

    // MARK: First launch with iCloud

    @MainActor
    func testFirstSyncBackupCopiesStoreAndWritesExportOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-firstsync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        do {
            let container = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
            store(container).commit(question: q("q"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        }
        let defaults = suite()
        XCTAssertTrue(FirstSyncBackup.ensure(storeURL: url, defaults: defaults, now: day(1)))
        XCTAssertTrue(defaults.bool(forKey: CloudSyncConfig.firstBackupKey(url)))
        let backups = folder.appendingPathComponent("StoreBackups")
        let made = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(made[0].hasPrefix("before-icloud-"))
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: backups.appendingPathComponent(made[0]).path))
        XCTAssertTrue(files.contains("default.store"))
        let export = try XCTUnwrap(files.first { $0.hasSuffix(".json") })
        let data = try Data(contentsOf: backups.appendingPathComponent(made[0]).appendingPathComponent(export))
        XCTAssertEqual(try StudyImport.decode(data).attemptRecords.count, 1)
        // Once only.
        XCTAssertTrue(FirstSyncBackup.ensure(storeURL: url, defaults: defaults, now: day(2)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
        // A fresh install has nothing to back up.
        let fresh = suite()
        XCTAssertTrue(FirstSyncBackup.ensure(storeURL: folder.appendingPathComponent("none.store"), defaults: fresh))
        XCTAssertTrue(fresh.bool(forKey: CloudSyncConfig.firstBackupKey(folder.appendingPathComponent("none.store"))))
    }

    @MainActor
    func testFailedFirstSyncBackupIsRetriedAtMostOnceADay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-retry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: url)
        struct Full: Error {}
        let defaults = suite()
        var exports = 0
        let failing: (URL) throws -> Void = { _ in exports += 1; throw Full() }
        XCTAssertFalse(FirstSyncBackup.ensure(storeURL: url, defaults: defaults, now: day(0), export: failing))
        XCTAssertFalse(FirstSyncBackup.ensure(storeURL: url, defaults: defaults, now: day(0, hour: 20), export: failing))
        XCTAssertEqual(exports, 1, "no second full copy the same day")
        XCTAssertTrue(FirstSyncBackup.ensure(storeURL: url, defaults: defaults, now: day(1, hour: 10), export: { _ in exports += 1 }))
        XCTAssertEqual(exports, 2)
        XCTAssertTrue(defaults.bool(forKey: CloudSyncConfig.firstBackupKey(url)))
    }

    @MainActor
    func testImportAfterICloudRestoredTheSameAnswersAddsNothing() throws {
        let source = try seededSource()
        let data = try exportData(source)
        let target = try memoryContainer()
        try StudyImport.apply(try StudyImport.decode(data), context: target.mainContext, scheduler: Scheduler(calendar: calendar))
        // What iCloud delivers: the same rows with times cut to the millisecond.
        for a in try target.mainContext.fetch(FetchDescriptor<AttemptRecord>()) {
            a.timestamp = Date(timeIntervalSince1970: Double(StudyDeduplication.ms(a.timestamp)) / 1000)
        }
        try target.mainContext.save()
        XCTAssertEqual(try StudyImport.preview(data: data, context: target.mainContext).summary.attempts, 0)
    }

    @MainActor
    func testWhenICloudCannotOpenTheSameStoreOpensLocallyWithItsData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-fallback-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = ModelConfiguration(schema: StudyDataStore.schema, url: folder.appendingPathComponent("default.store"),
                                       cloudKitDatabase: .none)
        do {
            let container = try StudyDataStore.open(local)
            store(container).commit(question: q("q"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        }
        struct NoCloud: Error {}
        let recovery = DataStoreRecovery(defaults: suite())
        var backupCalls = 0
        let failed = StudyDataStore.makeAppContainer(inMemory: false, cloud: true, local: local, recovery: recovery,
                                                     backup: { _ in backupCalls += 1; return true },
                                                     cloudOpener: { _ in throw NoCloud() })
        XCTAssertFalse(failed.syncing)
        XCTAssertEqual(backupCalls, 1)
        XCTAssertFalse(recovery.pending, "an iCloud failure is not a corrupt store")
        XCTAssertEqual(try failed.container.mainContext.fetchCount(FetchDescriptor<AttemptRecord>()), 1)

        var opened = false
        let noBackup = StudyDataStore.makeAppContainer(inMemory: false, cloud: true, local: local, recovery: recovery,
                                                       backup: { _ in false },
                                                       cloudOpener: { _ in opened = true; throw NoCloud() })
        XCTAssertFalse(noBackup.syncing)
        XCTAssertFalse(opened, "no iCloud until the first-sync backup succeeded")
    }

    // MARK: First join

    func testFirstJoinDecisionCoversEveryCase() {
        let record = FirstJoin.Record(device: "iPhone", attempts: 1200, date: day(0))
        // This device has nothing: just download, whatever iCloud holds (no wait for the check either).
        XCTAssertEqual(FirstJoin.decide(localAttempts: 0, probe: .hasData(true), remote: record), .enable(.empty))
        XCTAssertEqual(FirstJoin.decide(localAttempts: 0, probe: .undetermined(.offline), remote: nil), .enable(.empty))
        // iCloud empty: this device is first.
        XCTAssertEqual(FirstJoin.decide(localAttempts: 300, probe: .hasData(false), remote: nil), .enable(.first))
        // Both sides have data: ask; 建議 depends on the sizes.
        XCTAssertEqual(FirstJoin.decide(localAttempts: 300, probe: .hasData(true), remote: record),
                       .ask(local: 300, remote: 1200, recommendICloud: true))
        XCTAssertEqual(FirstJoin.decide(localAttempts: 800, probe: .hasData(true), remote: record),
                       .ask(local: 800, remote: 1200, recommendICloud: false))
        XCTAssertEqual(FirstJoin.decide(localAttempts: 30, probe: .hasData(true), remote: nil),
                       .ask(local: 30, remote: nil, recommendICloud: true))
        XCTAssertEqual(FirstJoin.decide(localAttempts: 300, probe: .hasData(true), remote: nil),
                       .ask(local: 300, remote: nil, recommendICloud: false))
        // Unknown: stay local with the reason, never merge.
        for status in [CloudSync.Status.offline, .noAccount, .unavailable] {
            XCTAssertEqual(FirstJoin.decide(localAttempts: 300, probe: .undetermined(status), remote: record), .stayLocal(status))
        }
        XCTAssertEqual(FirstJoin.Record(record.dictionary), record)
        XCTAssertNil(FirstJoin.Record(["device": "x"]))
    }

    func testFirstJoinProbeTimesOutAsWaitingForNetwork() async {
        let slow = await FirstJoin.probe(timeout: 0.05) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .hasData(true)
        }
        XCTAssertEqual(slow, .undetermined(.offline))
        let fast = await FirstJoin.probe(timeout: 2) { .hasData(false) }
        XCTAssertEqual(fast, .hasData(false))
    }

    func testFirstJoinDecisionIsStoredPerStoreFile() {
        let defaults = suite()
        let a = URL(fileURLWithPath: "/tmp/default.store"), b = URL(fileURLWithPath: "/tmp/icloud-debug.store")
        XCTAssertNil(FirstJoin.decision(storeURL: a, defaults: defaults))
        FirstJoin.save(.merge, storeURL: a, defaults: defaults)
        XCTAssertEqual(FirstJoin.decision(storeURL: a, defaults: defaults), .merge)
        XCTAssertNil(FirstJoin.decision(storeURL: b, defaults: defaults))
    }

    @MainActor
    func testUseICloudExportsAndMovesTheLocalStoreAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-join-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        do {
            let container = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
            let s = store(container)
            s.commit(question: q("a"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
            s.commit(question: q("b"), chosen: "A", correct: true, unsure: false, reason: nil, now: day(0))
        }
        XCTAssertEqual(try FirstJoin.localAttemptCount(storeURL: url), 2)
        let defaults = suite()
        let export = try FirstJoin.replaceLocalStore(storeURL: url, now: day(1), defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: FirstJoin.exportPathKey), export.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved aside, so a fresh store downloads iCloud's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.deletingLastPathComponent().path))
        XCTAssertTrue(export.path.contains("replaced-by-icloud-"))
        XCTAssertEqual(try StudyImport.decode(Data(contentsOf: export)).attemptRecords.count, 2)
        let moved = try XCTUnwrap(FileManager.default.subpaths(atPath: folder.appendingPathComponent("StoreBackups").path))
        XCTAssertTrue(moved.contains { $0.hasSuffix("default.store") })
        XCTAssertEqual(try FirstJoin.localAttemptCount(storeURL: url), 0)
        // Adding them back later is the ordinary import.
        let fresh = try memoryContainer()
        XCTAssertEqual(try StudyImport.preview(data: Data(contentsOf: export), context: fresh.mainContext).summary.attempts, 2)
    }

    @MainActor
    func testFailedMoveDuringReplaceRollsBackAndKeepsTheExportReachable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-rollback-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        do {
            let container = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
            store(container).commit(question: q("a"), chosen: "B", correct: false, unsure: false, reason: nil, now: day(0))
        }
        // Make sure there is a second file to fail on after the main file moved.
        if !FileManager.default.fileExists(atPath: url.path + "-wal") { try Data().write(to: URL(fileURLWithPath: url.path + "-wal")) }
        struct DiskFull: Error {}
        let defaults = suite()
        XCTAssertThrowsError(try FirstJoin.replaceLocalStore(storeURL: url, now: day(1), defaults: defaults) { from, to in
            if from.lastPathComponent.hasSuffix("-wal") { throw DiskFull() }
            try FileManager.default.moveItem(at: from, to: to)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the main file is moved back")
        XCTAssertEqual(try FirstJoin.localAttemptCount(storeURL: url), 1)
        let exportPath = try XCTUnwrap(defaults.string(forKey: FirstJoin.exportPathKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportPath))
    }

    @MainActor
    func testPrepareForSyncFillsIDsAndWholeMillisecondsBeforeICloudOpens() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-prepare-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        let subMillisecond = day(0).addingTimeInterval(0.000_6)
        do {
            // A 0.2.x store: no synced IDs, times finer than a millisecond.
            let v4 = Schema(versionedSchema: SchemaV4.self)
            let container = try ModelContainer(for: v4, configurations: [ModelConfiguration(schema: v4, url: url, cloudKitDatabase: .none)])
            let record = SchemaV4.QuestionRecord(questionID: "q", subject: Subjects.all[0], now: subMillisecond)
            container.mainContext.insert(record)
            let attempt = SchemaV4.AttemptRecord(questionID: "q", subject: record.subject, timestamp: subMillisecond,
                                                 chosen: "B", correct: false, reason: nil, unsure: false)
            container.mainContext.insert(attempt)
            attempt.record = record
            try container.mainContext.save()
        }
        let defaults = suite()
        XCTAssertTrue(FirstJoin.prepareForSync(storeURL: url, defaults: defaults, scheduler: Scheduler(calendar: calendar)))
        XCTAssertTrue(defaults.bool(forKey: FirstJoin.preparedKey(url)))
        let container = try ModelContainer(for: StudyDataStore.schema, migrationPlan: StudyMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)])
        let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<QuestionRecord>()).first)
        let attempt = try XCTUnwrap(record.attempts?.first)
        XCTAssertNotNil(record.cardID)
        XCTAssertNotNil(attempt.attemptID)
        XCTAssertTrue(StudyDeduplication.isWholeMillisecond(attempt.timestamp))
        XCTAssertTrue(StudyDeduplication.isWholeMillisecond(record.firstSeen))
        XCTAssertEqual(StudyDeduplication.ms(attempt.timestamp), StudyDeduplication.ms(day(0)))
        XCTAssertEqual(record.fsrsVersion, StudyReplay.version)
    }

    func testWholeMillisecondsSurviveTheReferenceEpochRoundTrip() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let k = Int64.random(in: 1_600_000_000_000...1_900_000_000_000, using: &generator)
            // How CloudKit / Core Data hands back a whole-millisecond time: a Double relative to 2001.
            let stored = Date(timeIntervalSinceReferenceDate: Double(k - 978_307_200_000) / 1000)
            XCTAssertEqual(StudyDeduplication.ms(stored), k)
            XCTAssertTrue(StudyDeduplication.isWholeMillisecond(stored))
            XCTAssertEqual(StudyDeduplication.ms(stored.wholeMillisecond), k, "cutting is idempotent")
            let fine = Date(timeIntervalSince1970: Double(k) / 1000 + 0.000_7)
            XCTAssertEqual(StudyDeduplication.ms(fine.wholeMillisecond), k, "writes cut down, never up")
        }
    }

    /// One device still has its own card with a sub-millisecond time (written before 0.3.0); the other received it
    /// from CloudKit as a whole millisecond relative to 2001. After the merge both keep the same card.
    @MainActor
    func testNearTiesResolveTheSameOnBothDevicesAfterWholeMillisecondCut() throws {
        let k = Int64(1_759_900_000_123)
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let high = UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000003")!
        func device(_ mineTime: Date) throws -> UUID? {
            let container = try memoryContainer()
            let context = container.mainContext
            let mine = deviceCard(context, "q", at: mineTime, correct: false)
            mine.cardID = high
            let theirs = deviceCard(context, "q", at: Date(timeIntervalSinceReferenceDate: Double(k - 978_307_200_000) / 1000),
                                    correct: true)
            theirs.cardID = low
            try context.save()
            CloudSync.merge(container: container)
            return try context.fetch(FetchDescriptor<QuestionRecord>()).first?.cardID
        }
        let phone = try device(Date(timeIntervalSince1970: Double(k) / 1000 + 0.000_6))  // rounds up without the cut
        let pad = try device(Date(timeIntervalSinceReferenceDate: Double(k - 978_307_200_000) / 1000))
        XCTAssertEqual(phone, low)
        XCTAssertEqual(pad, low)
    }

    // MARK: SavedNote (0.3.0 schema V5)

    @MainActor
    func testV4StoreMigratesToV5KeepingDataAndAcceptingSavedNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opto-v5-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        do {
            let v4 = Schema(versionedSchema: SchemaV4.self)
            let container = try ModelContainer(for: v4, configurations: [ModelConfiguration(schema: v4, url: url, cloudKitDatabase: .none)])
            let record = SchemaV4.QuestionRecord(questionID: "q", subject: Subjects.all[0], now: day(0))
            record.fsrsVersion = StudyReplay.version
            container.mainContext.insert(record)
            let attempt = SchemaV4.AttemptRecord(questionID: "q", subject: record.subject, timestamp: day(0), chosen: "B",
                                                 correct: false, reason: nil, unsure: false)
            container.mainContext.insert(attempt)
            attempt.record = record
            let exam = SchemaV4.MockExam(subject: record.subject, modeRaw: ExamMode.wholePaper.rawValue, title: "t",
                                         questionIDs: ["q"], now: day(0))
            container.mainContext.insert(exam)
            try container.mainContext.save()
        }
        let migrated = try StudyDataStore.open(ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none))
        let context = migrated.mainContext
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<QuestionRecord>()).first)
        XCTAssertEqual(record.attempts?.count, 1)
        // The open-time repair gives pre-0.3.0 rows their synced IDs.
        XCTAssertNotNil(record.cardID)
        XCTAssertFalse(record.createdByRepair)
        XCTAssertNotNil(record.attempts?.first?.attemptID)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<MockExam>()).first?.syncID)
        context.insert(SavedNote(pointID: "p", unitID: "u", subject: Subjects.all[0], title: "t", misconception: "m",
                                 fix: "f", source: "nightly", generatedAt: day(0), questionIDs: ["q"], now: day(1)))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedNote>()), 1)
    }

    @MainActor
    func testSavedNotesDeduplicateByPointAndGenerationKeepingTheEarliestSave() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        func saved(_ point: String, generated: Date?, savedAt: Date) -> SavedNote {
            let n = SavedNote(pointID: point, unitID: "u", subject: Subjects.all[0], title: point, misconception: "m",
                              fix: "f", source: "review", generatedAt: generated, questionIDs: [], now: savedAt)
            context.insert(n)
            return n
        }
        let first = saved("p", generated: day(0), savedAt: day(1))
        _ = saved("p", generated: day(0), savedAt: day(2))          // same note saved on the iPad
        let other = saved("p", generated: day(3), savedAt: day(4))  // a newer note of the same point
        try context.save()
        CloudSync.merge(container: container)
        let ids = Set(try context.fetch(FetchDescriptor<SavedNote>()).map(\.noteID))
        XCTAssertEqual(ids, [first.noteID, other.noteID])

        // Export → import into an empty store, twice: no duplicates.
        let data = try exportData(container)
        let target = try memoryContainer()
        let summary = try StudyImport.apply(try StudyImport.decode(data), context: target.mainContext,
                                            scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(summary.savedNotes, 2)
        XCTAssertTrue(try StudyImport.preview(data: data, context: target.mainContext).summary.isEmpty)
        try StudyImport.apply(try StudyImport.decode(data), context: target.mainContext, scheduler: Scheduler(calendar: calendar))
        XCTAssertEqual(Set(try target.mainContext.fetch(FetchDescriptor<SavedNote>()).map(\.noteID)), ids)
    }

    func testDebugDataArgumentsKeepTheStoreLocal() {
        #if DEBUG
        // Debug builds sync only with -iCloud, never with data arguments, and then in their own store file.
        let container = "iCloud.org.example.test"
        XCTAssertFalse(CloudSyncConfig.wantsCloud(arguments: ["app", "-iCloud"], containerID: nil))
        XCTAssertFalse(CloudSyncConfig.wantsCloud(arguments: ["app", "-tab", "2"], containerID: container))
        XCTAssertTrue(CloudSyncConfig.wantsCloud(arguments: ["app", "-iCloud"], containerID: container))
        XCTAssertFalse(CloudSyncConfig.wantsCloud(arguments: ["app", "-iCloud", "-seedDemo"], containerID: container))
        XCTAssertFalse(CloudSyncConfig.wantsCloud(arguments: ["app", "-iCloud", "-resetAll"], containerID: container))
        MainActor.assumeIsolated {
            XCTAssertEqual(CloudSyncConfig.storeConfiguration(cloud: true).url.lastPathComponent, CloudSyncConfig.debugCloudStoreName)
            XCTAssertEqual(CloudSyncConfig.storeConfiguration(cloud: false).url, StudyDataStore.localConfiguration.url)
        }
        #endif
    }
}
