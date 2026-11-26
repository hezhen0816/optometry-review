import XCTest
import SwiftData
@testable import OptometryReview

final class UsageLogTests: XCTestCase {
    private let device = UsageDevice(id: "12345678-1234-1234-1234-123456789012", name: "", model: "iPhone15,2",
                                     os: "26.1", app: "1.0 (12)")

    private func queueURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID())", isDirectory: true)
            .appendingPathComponent("usage-queue.jsonl")
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "opto.usage.\(UUID())")! }

    private func event(_ id: String) -> [String: Any] {
        ["id": id, "t": "2026-10-07T21:03:05+08:00", "type": "export"]
    }

    @MainActor
    private func logger(url: URL, defaults: UserDefaults? = nil, transport: @escaping UsageLog.Transport) -> UsageLog {
        UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-only", fallbackBaseURLs: []),
                 defaults: defaults ?? self.defaults(), queueURL: url, device: device,
                 isTesting: false, isSimulator: false, arguments: [], transport: transport)
    }

    private func payload(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testQueuePersistsAndTrimsOldestAfterAppendAndReload() throws {
        let url = queueURL()
        let queue = try UsageEventQueue(url: url, capacity: 3)
        for i in 0..<5 { try queue.append(event(String(i))) }
        XCTAssertEqual(queue.events.compactMap { $0["id"] as? String }, ["2", "3", "4"])
        let reloaded = try UsageEventQueue(url: url, capacity: 2)
        XCTAssertEqual(reloaded.events.compactMap { $0["id"] as? String }, ["3", "4"])
        try reloaded.remove(ids: ["3"])
        XCTAssertEqual(try UsageEventQueue(url: url).events.first?["id"] as? String, "4")
    }

    func testQueueDefaultCapIsTwentyThousand() throws {
        let url = queueURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for i in 0...20_000 {
            data.append(try JSONSerialization.data(withJSONObject: event(String(i))))
            data.append(10)
        }
        try data.write(to: url)
        let queue = try UsageEventQueue(url: url)
        XCTAssertEqual(queue.events.count, 20_000)
        XCTAssertEqual(queue.events.first?["id"] as? String, "1")
        try queue.append(event("20001"))
        XCTAssertEqual(queue.events.first?["id"] as? String, "2")
        XCTAssertEqual(try UsageEventQueue(url: url).events.count, 20_000)
    }

    func testQueueRepairsInterruptedLastLineBeforeAppending() throws {
        let url = queueURL()
        let queue = try UsageEventQueue(url: url)
        try queue.append(event("good"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"unfinished".utf8))
        try handle.close()
        let reloaded = try UsageEventQueue(url: url)
        try reloaded.append(event("next"))
        XCTAssertEqual(try UsageEventQueue(url: url).events.compactMap { $0["id"] as? String }, ["good", "next"])
    }

    func testOversizedEventIsNotQueued() throws {
        let queue = try UsageEventQueue(url: queueURL())
        try queue.append(event("small").merging(["extra": String(repeating: "界", count: 1500)]) { _, b in b })
        XCTAssertTrue(queue.events.isEmpty)
    }

    @MainActor
    func testBatchSplittingAndPayloadMatchesFormat() async throws {
        let url = queueURL()
        let queue = try UsageEventQueue(url: url)
        for i in 0..<401 { try queue.append(event(String(i))) }
        let defaults = defaults()
        defaults.set("主手機", forKey: SettingsKey.deviceName)
        var sizes: [Int] = []
        let log = logger(url: url, defaults: defaults) { request, data in
            XCTAssertEqual(request.url?.path, "/events")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.payload(data)
            XCTAssertEqual(Set(body.keys), ["device", "events"])
            let device = try XCTUnwrap(body["device"] as? [String: String])
            XCTAssertEqual(device, ["id": self.device.id, "name": "主手機", "model": "iPhone15,2", "os": "26.1", "app": "1.0 (12)"])
            let events = try XCTUnwrap(body["events"] as? [[String: Any]])
            XCTAssertEqual(Set(events[0].keys), ["id", "t", "type"])
            sizes.append(events.count)
            return 200
        }
        await log.flush()
        XCTAssertEqual(sizes, [200, 200, 1])
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
    }

    @MainActor
    func testBatchesAlsoRespectBodyByteLimit() async throws {
        let url = queueURL()
        let queue = try UsageEventQueue(url: url)
        for i in 0..<200 { try queue.append(event(String(i)).merging(["extra": String(repeating: "x", count: 3800)]) { _, b in b }) }
        var sizes: [Int] = []
        let log = logger(url: url) { _, data in
            XCTAssertLessThanOrEqual(data.count, 256 * 1024)
            sizes.append((try self.payload(data)["events"] as! [[String: Any]]).count)
            return 200
        }
        await log.flush()
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertEqual(sizes.reduce(0, +), 200)
    }

    @MainActor
    func testFailureKeepsSameIDsAcrossRestartAndRetry() async throws {
        let url = queueURL()
        var first: Data?
        let log = logger(url: url) { _, body in first = body; return 503 }
        log.log("answer", ["qid": "q1", "correct": false, "reason": NSNull()])
        await log.flush()
        XCTAssertEqual(try UsageEventQueue(url: url).events.count, 1)
        var retried: Data?
        let restarted = logger(url: url) { _, body in retried = body; return 200 }
        await restarted.flush()
        XCTAssertEqual(first, retried)
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
    }

    @MainActor
    func testTransportErrorRetainsQueue() async throws {
        let url = queueURL()
        let log = logger(url: url) { _, _ in throw URLError(.notConnectedToInternet) }
        log.log("export")
        await log.flush()
        XCTAssertEqual(try UsageEventQueue(url: url).events.count, 1)
    }

    @MainActor
    func testEventsAddedDuringUploadSurviveBatchRemoval() async throws {
        let url = queueURL()
        var calls = 0
        var log: UsageLog?
        log = logger(url: url) { _, _ in
            calls += 1
            if calls == 1 {
                log?.log("export")
                await log?.flush()
            }
            return 200
        }
        log?.log("export")
        await log?.flush()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
        log = nil
    }

    @MainActor
    func testDisabledConditionsDoNotQueueOrUpload() async throws {
        for condition in ["setting", "token", "tests", "simulator"] {
            let url = queueURL()
            let defaults = defaults()
            if condition == "setting" { defaults.set(false, forKey: SettingsKey.usageLogEnabled) }
            let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: condition == "token" ? nil : "test-only", fallbackBaseURLs: []),
                               defaults: defaults, queueURL: url, device: device, isTesting: condition == "tests",
                               isSimulator: condition == "simulator", arguments: [], transport: { _, _ in
                XCTFail("Disabled logger uploaded")
                return 200
            })
            XCTAssertFalse(log.isEnabled)
            log.log("export")
            await log.flush()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testSimulatorDebugOverrideAndUnsetDefaults() async throws {
        let url = queueURL()
        let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-only", fallbackBaseURLs: []),
                           defaults: defaults(), queueURL: url, device: device, isTesting: false, isSimulator: true,
                           arguments: ["app", "-usageBaseURL", "http://127.0.0.1:4321"], transport: { request, body in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4321/events")
            XCTAssertEqual((try self.payload(body)["device"] as? [String: String])?["name"], "")
            return 200
        })
        #if DEBUG
        XCTAssertTrue(log.isEnabled)
        log.log("export")
        await log.flush()
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
        #else
        XCTAssertFalse(log.isEnabled)
        #endif
    }

    @MainActor
    func testDebugOverrideDoesNotBypassMissingTokenOrUnitTests() {
        for testing in [true, false] {
            let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: testing ? "test-only" : nil, fallbackBaseURLs: []),
                               defaults: defaults(), queueURL: queueURL(), device: device, isTesting: testing, isSimulator: true,
                               arguments: ["app", "-usageBaseURL", "http://127.0.0.1:4321"])
            XCTAssertFalse(log.isEnabled)
        }
        XCTAssertFalse(UsageLog.shared.isEnabled)
    }

    func testTimestampContainsLocalOffset() {
        let date = Date(timeIntervalSince1970: 1_791_378_185)
        let timestamp = UsageLog.timestamp(date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        XCTAssertTrue(timestamp.hasSuffix("+08:00"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: timestamp))
    }

    @MainActor
    func testSettingEventsOnlyForChangedDocumentedKeys() throws {
        let url = queueURL()
        let defaults = defaults()
        let log = logger(url: url, defaults: defaults) { _, _ in return 200 }
        log.recordSettingsChanges()
        defaults.set(SettingsKey.defaultDailyGoal, forKey: SettingsKey.dailyGoal)
        defaults.set(true, forKey: SettingsKey.usageLogEnabled)
        defaults.set("ignored", forKey: "untracked")
        log.recordSettingsChanges()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        defaults.set(30, forKey: SettingsKey.dailyGoal)
        defaults.set("主手機", forKey: SettingsKey.deviceName)
        log.recordSettingsChanges()
        log.recordSettingsChanges()
        let events = try UsageEventQueue(url: url).events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.compactMap { $0["key"] as? String }), ["dailyGoal", "deviceName"])
        XCTAssertEqual(events.first?["value"] as? String, "30")
        defaults.set(false, forKey: SettingsKey.usageLogEnabled)
        log.recordSettingsChanges()
        log.log("export")
        XCTAssertEqual(try UsageEventQueue(url: url).events.count, 2)
        defaults.set(true, forKey: SettingsKey.usageLogEnabled)
        log.recordSettingsChanges()
        XCTAssertEqual(try UsageEventQueue(url: url).events.last?["key"] as? String, "usageLogEnabled")
    }

    @MainActor
    func testNewRatioSettingEventsUseDefaultsThenOnlyEmitChangedValues() throws {
        let url = queueURL()
        let defaults = defaults()
        let log = logger(url: url, defaults: defaults) { _, _ in return 200 }
        defaults.set(NewRatioMode.normal.rawValue, forKey: SettingsKey.newRatioMode)
        defaults.set(25, forKey: SettingsKey.customNewPercent)
        log.recordSettingsChanges()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        defaults.set(NewRatioMode.custom.rawValue, forKey: SettingsKey.newRatioMode)
        defaults.set(50, forKey: SettingsKey.customNewPercent)
        log.recordSettingsChanges()
        log.recordSettingsChanges()
        let events = try UsageEventQueue(url: url).events
        XCTAssertEqual(events.count, 2)
        let values = Dictionary(events.compactMap { event -> (String, String)? in
            guard let key = event["key"] as? String, let value = event["value"] as? String else { return nil }
            return (key, value)
        }, uniquingKeysWith: { _, b in b })
        XCTAssertEqual(values[SettingsKey.newRatioMode], "custom")
        XCTAssertEqual(values[SettingsKey.customNewPercent], "50")
    }

    @MainActor
    func testSettingsNotificationIsObservedCentrally() throws {
        let url = queueURL()
        let defaults = defaults()
        let log = logger(url: url, defaults: defaults) { _, _ in return 200 }
        defaults.set(true, forKey: SettingsKey.reminderEnabled)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(try UsageEventQueue(url: url).events.last?["key"] as? String, "reminderEnabled")
        withExtendedLifetime(log) {}
    }

    @MainActor
    func testFiftyEventsAutomaticallyFlush() async throws {
        let url = queueURL()
        let sent = expectation(description: "Threshold upload")
        let log = logger(url: url) { _, body in
            XCTAssertEqual((try self.payload(body)["events"] as? [[String: Any]])?.count, 50)
            sent.fulfill()
            return 200
        }
        for _ in 0..<50 { log.log("export") }
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
    }

    @MainActor
    func testSessionBoundariesAndSeconds() async throws {
        let url = queueURL()
        var time = Date(timeIntervalSince1970: 1_000_000)
        var events: [[String: Any]] = []
        let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-only", fallbackBaseURLs: []),
                           defaults: defaults(), queueURL: url, device: device, isTesting: false, isSimulator: false,
                           arguments: [], now: { time }) { _, body in
            events += try self.payload(body)["events"] as! [[String: Any]]
            return 200
        }
        log.sceneActive()
        log.sceneActive()
        time = time.addingTimeInterval(25)
        log.sceneBackground()
        log.sceneBackground()
        await log.flush()
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["session_start", "session_end"])
        XCTAssertEqual(events.last?["seconds"] as? Double, 25)
    }

    @MainActor
    func testCommitEmitsAnswerViaInjectedSink() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var recorded: [(String, [String: Any])] = []
        var store = StudyStore(context: container.mainContext, scheduler: Scheduler())
        store.usageSink = { recorded.append(($0, $1)) }
        let q = Question(id: "q", code: "115100", year: 115, examKind: ExamKind.general,
                         subject: Subjects.all[0], number: 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                         answer: ["B"], originalAnswer: "B", corrected: false, correctionNote: nil, allCredit: false,
                         hasFigure: false, needsReview: false)
        store.commit(question: q, chosen: "A", correct: false, unsure: false, reason: "算錯", confident: true,
                     source: "today", seconds: 12)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].0, "answer")
        let fields = recorded[0].1
        XCTAssertEqual(Set(fields.keys), ["qid", "subject", "source", "correct", "unsure", "confident", "reason", "seconds", "intervalDays", "stability", "mastered", "chosen"])
        XCTAssertEqual(fields["chosen"] as? String, "A")
        XCTAssertEqual(fields["qid"] as? String, "q")
        XCTAssertEqual(fields["source"] as? String, "today")
        XCTAssertEqual(fields["correct"] as? Bool, false)
        XCTAssertEqual(fields["confident"] as? Bool, true)
        XCTAssertEqual(fields["reason"] as? String, "算錯")
        XCTAssertEqual(fields["seconds"] as? Double, 12)
        XCTAssertEqual(fields["intervalDays"] as? Int, 1)
        XCTAssertEqual(fields["stability"] as? Double, 0.21)
        XCTAssertEqual(fields["mastered"] as? Bool, false)
        store.commit(question: q, chosen: "B", correct: true, unsure: true, reason: "ignored", source: "extra")
        XCTAssertTrue(recorded[1].1["reason"] is NSNull)
        XCTAssertNil(recorded[0].1["revealed"])
        let q2 = Question(id: "q2", code: "115100", year: 115, examKind: ExamKind.general,
                          subject: Subjects.all[0], number: 2, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                          answer: ["B"], originalAnswer: "B", corrected: false, correctionNote: nil, allCredit: false,
                          hasFigure: false, needsReview: false)
        // 「看解答」 is a wrong answer plus `revealed`; the other fields keep their shape.
        store.commit(question: q2, chosen: "", correct: false, unsure: false, reason: "觀念不懂", revealed: true, source: "today")
        XCTAssertEqual(recorded[2].1["revealed"] as? Bool, true)
        XCTAssertEqual(recorded[2].1["correct"] as? Bool, false)
        XCTAssertEqual(Set(recorded[2].1.keys), ["qid", "subject", "source", "correct", "unsure", "confident", "reason", "intervalDays", "stability", "mastered", "revealed"])
        XCTAssertNil(recorded[1].1["seconds"])
    }

    @MainActor
    func testReviewContextAndAllAnswerSources() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var fields: [[String: Any]] = []
        var store = StudyStore(context: container.mainContext)
        store.usageSink = { _, event in fields.append(event) }
        let q = Question(id: "q", code: "115100", year: 115, examKind: ExamKind.general,
                         subject: Subjects.all[0], number: 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                         answer: ["B"], originalAnswer: "B", corrected: false, correctionNote: nil, allCredit: false,
                         hasFigure: false, needsReview: false)
        let context = UUID()
        defer { UsageLog.shared.leaveAnswerContext(context) }
        for source in ["today", "extra", "mistakes", "practice", "custom"] {
            UsageLog.shared.enterAnswerContext(context, source: source)
            store.commit(question: q, chosen: "B", correct: true, unsure: false, reason: nil)
            XCTAssertEqual(fields.last?["source"] as? String, source)
        }
        store.commit(question: q, chosen: "B", correct: true, unsure: false, reason: nil, source: "exam")
        XCTAssertEqual(fields.last?["source"] as? String, "exam")
        store.commit(question: q, chosen: "B", correct: true, unsure: false, reason: nil, source: "exam", usageSource: "fullMock")
        XCTAssertEqual(fields.last?["source"] as? String, "fullMock")
        XCTAssertEqual(UsageLog.answerSource("oldUnknownValue"), "practice")
    }

    @MainActor
    func testExamEventsAndFullMockSubmissionAreEmittedOnce() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var recorded: [(String, [String: Any])] = []
        var store = StudyStore(context: container.mainContext)
        store.usageSink = { recorded.append(($0, $1)) }
        let questions = Subjects.all.map { subject in
            Question(id: "T_\(subject)_1", code: "T", year: 115, examKind: ExamKind.general, subject: subject, number: 1,
                     stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["B"],
                     originalAnswer: "B", corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
        }
        let papers = questions.map { q in
            Paper(code: q.code, year: q.year, examKind: q.examKind, sessionNote: nil, subject: q.subject,
                  fileCode: "", paperCode: nil, calculatorAllowed: false, questionIDs: [q.id], hasCorrectedQuestions: false)
        }
        let bank = QuestionBank(questions: questions, papers: papers)
        let session = try XCTUnwrap(PaperCatalog.sessions(bank.papers, kind: ExamKind.general).first)
        let full = store.startFullMock(session: session)
        for _ in Subjects.all {
            let exam = try XCTUnwrap(store.nextSubjectExam(of: full, bank: bank))
            XCTAssertTrue(store.nextSubjectExam(of: full, bank: bank) === exam)
            exam.answers = ["B"]
            exam.seconds = [9]
            store.finish(exam: exam, bank: bank, elapsed: 10, auto: false)
            store.finish(exam: exam, bank: bank, elapsed: 10, auto: false)
        }
        store.completeFullMock(full, bank: bank)
        store.completeFullMock(full, bank: bank)
        XCTAssertEqual(recorded.filter { $0.0 == "exam_start" }.count, 5)
        let submits = recorded.filter { $0.0 == "exam_submit" }
        XCTAssertEqual(submits.count, 5)
        XCTAssertEqual(Set(submits[0].1.keys), ["examId", "subject", "mode", "answered", "count", "score", "seconds", "counted"])
        XCTAssertEqual(submits[0].1["counted"] as? Bool, true)
        XCTAssertEqual(submits[0].1["seconds"] as? Double, 10)
        let answers = recorded.filter { $0.0 == "answer" }
        XCTAssertEqual(answers.count, 5)
        XCTAssertTrue(answers.allSatisfy { $0.1["source"] as? String == "fullMock" && $0.1["seconds"] as? Double == 9 })
        let totals = recorded.filter { $0.0 == "fullmock_submit" }
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].1["average"] as? Double, 2)
        XCTAssertEqual(totals[0].1["passed"] as? Bool, false)
        XCTAssertEqual((totals[0].1["scores"] as? [String: Int])?.count, 5)
    }

    @MainActor
    func testLocalServerRoundTripWhenHarnessConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["OPTO_USAGE_TEST_URL"], let url = URL(string: base),
              let token = env["OPTO_USAGE_TEST_TOKEN"], url.host == "127.0.0.1" else {
            throw XCTSkip("Local end-to-end harness not configured")
        }
        let queue = queueURL()
        let session = URLSession(configuration: .ephemeral)
        let log = UsageLog(config: AIConfig(baseURL: url, token: token, fallbackBaseURLs: []), defaults: defaults(), queueURL: queue,
                           device: device, isTesting: false, isSimulator: false, arguments: [])
        log.log("session_start")
        log.log("answer", ["qid": "harness-q", "subject": "視覺光學", "source": "today", "correct": true,
                           "unsure": false, "confident": false, "reason": NSNull(), "seconds": 7,
                           "stageBefore": 0, "stageAfter": 0])
        await log.flush()
        XCTAssertTrue(try UsageEventQueue(url: queue).events.isEmpty)
        var request = URLRequest(url: url.appendingPathComponent("events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let events = try XCTUnwrap(payload(data)["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["qid"] as? String == "harness-q" && $0["type"] as? String == "answer" })
    }
}
