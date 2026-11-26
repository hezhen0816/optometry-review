import XCTest
import SwiftData
@testable import OptometryReview

/// 1.5: leaderboard client, unit overview figures, the 錯題 definition, year filters, upload back-off, AI layout.
final class Release15Tests: XCTestCase {

    // MARK: Leaderboard decoding

    func testBoardDecodesJoinedAndNotJoined() throws {
        let off = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(#"{"joined": false}"#.utf8))
        XCTAssertFalse(off.joined)
        XCTAssertTrue(off.entries.isEmpty)

        let json = #"""
        {"joined": true, "week": {"start": "2026-10-05", "end": "2026-10-11"},
         "entries": [
          {"id": "aaaaaaaaaaaa", "name": "Amy", "rank": 1, "correct": 86, "days": 5, "accuracy": 0.7134, "me": false},
          {"id": "bbbbbbbbbbbb", "name": "小禾", "rank": 2, "correct": 74, "days": 4, "accuracy": 0.68, "me": true},
          {"id": "cccccccccccc", "name": "阿凱", "rank": 2, "correct": 74, "days": 4, "accuracy": null, "me": false}]}
        """#
        let board = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(json.utf8))
        XCTAssertTrue(board.joined)
        XCTAssertEqual(board.week?.label, "10/5 – 10/11")
        XCTAssertEqual(board.mine?.name, "小禾")
        XCTAssertNil(board.entries[2].accuracy)
        XCTAssertNil(board.lastWeekCorrect)
        XCTAssertEqual(LeaderboardText.accuracy(0.7134), "71%")
        XCTAssertEqual(LeaderboardText.accuracy(0.9996), "99%")
        XCTAssertEqual(LeaderboardText.accuracy(1), "100%")
        XCTAssertEqual(LeaderboardText.accuracy(nil), "—")
    }

    func testMemberDecodesAndWeekDayIndexUsesTaipeiDates() throws {
        let json = #"""
        {"name": "Amy", "rank": 1, "correct": 86, "days": 5, "accuracy": 0.71,
         "daily": [20, 14, 18, 22, 12, 0, 0], "subjects": {"視覺光學": 18, "低視力學": 10}}
        """#
        let m = try JSONDecoder().decode(LeaderboardMember.self, from: Data(json.utf8))
        XCTAssertEqual(m.daily.count, 7)
        XCTAssertEqual(m.subjects["視覺光學"], 18)
        let week = LeaderboardWeek(start: "2026-10-05", end: "2026-10-11")
        // 2026-10-09 23:30 Taipei is Friday (index 4) even though it is still Friday afternoon in UTC.
        let friday = ISO8601DateFormatter().date(from: "2026-10-09T15:30:00Z")!
        XCTAssertEqual(week.dayIndex(of: friday), 4)
        let nextMonday = ISO8601DateFormatter().date(from: "2026-10-11T16:30:00Z")!
        XCTAssertNil(week.dayIndex(of: nextMonday))
    }

    func testNameRulesMatchServer() {
        XCTAssertEqual(LeaderboardText.validName("  小禾 "), "小禾")
        XCTAssertNil(LeaderboardText.validName("   "))
        XCTAssertNil(LeaderboardText.validName(String(repeating: "字", count: 13)))
        XCTAssertNil(LeaderboardText.validName("a\u{200B}b"))
        XCTAssertNil(LeaderboardText.validName("a\u{0007}"))
        XCTAssertEqual(LeaderboardText.defaultName(deviceID: "3f2a9c1e-0000-0000-0000-000000000000"), "3F2A")
    }

    // MARK: Leaderboard client

    func testClientRequestsUseAuthHeadersAndExactProfileBody() async throws {
        var seen: [URLRequest] = []
        let client = LeaderboardClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "tok", deviceID: "dev-1", fallbackBaseURLs: []) { req in
            seen.append(req)
            if req.url!.path.hasSuffix("profile") {
                return (Data(#"{"id": "0123456789ab", "name": "小禾", "joined": true}"#.utf8), 200)
            }
            if req.url!.path.contains("member") { return (Data(), 404) }
            return (Data(#"{"joined": false}"#.utf8), 200)
        }
        let profile = try await client.setProfile(name: "小禾", joined: true)
        XCTAssertEqual(profile.id, "0123456789ab")
        let post = try XCTUnwrap(seen.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/leaderboard/profile")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Device-Id"), "dev-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: post.httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["name", "joined"])

        let board = try await client.board()
        XCTAssertFalse(board.joined)
        XCTAssertEqual(seen.last?.httpMethod, "GET")
        XCTAssertEqual(seen.last?.url?.path, "/leaderboard")

        do {
            _ = try await client.member(id: "0123456789ab")
            XCTFail("404 should throw")
        } catch let e as LeaderboardError { XCTAssertEqual(e, .notFound) }
        XCTAssertEqual(seen.last?.url?.path, "/leaderboard/member/0123456789ab")

        let before = seen.count
        do {
            _ = try await client.member(id: "../events")
            XCTFail("bad id should throw")
        } catch let e as LeaderboardError { XCTAssertEqual(e, .notFound) }
        XCTAssertEqual(seen.count, before, "a malformed id is never sent")
    }

    func testClientMapsStatusesAndTransportErrors() async {
        XCTAssertEqual(LeaderboardClient.map(status: 400), .invalidName)
        XCTAssertEqual(LeaderboardClient.map(status: 401), .unauthorized)
        XCTAssertEqual(LeaderboardClient.map(status: 403), .blocked)
        XCTAssertEqual(LeaderboardClient.map(status: 429), .rateLimited)
        XCTAssertEqual(LeaderboardClient.map(status: 500), .server(500))
        let client = LeaderboardClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t", deviceID: "d", fallbackBaseURLs: []) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await client.board()
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? LeaderboardError, .unreachable) }
    }

    private final class FakeService: LeaderboardService {
        var serverJoined = false
        var profiles: [(String, Bool)] = []
        func board() async throws -> LeaderboardBoard {
            serverJoined ? LeaderboardBoard(joined: true, week: LeaderboardWeek(start: "2026-10-05", end: "2026-10-11"),
                                            entries: [LeaderboardEntry(id: "0123456789ab", name: "小禾", rank: 1, correct: 3,
                                                                       days: 1, accuracy: 0.75, me: true)])
                : LeaderboardBoard(joined: false, week: nil, entries: [])
        }
        func setProfile(name: String, joined: Bool) async throws -> LeaderboardProfile {
            profiles.append((name, joined))
            serverJoined = joined
            return LeaderboardProfile(id: "0123456789ab", name: name, joined: joined)
        }
        func member(id: String) async throws -> LeaderboardMember { throw LeaderboardError.notFound }
    }

    @MainActor
    func testModelJoinLeaveAndRejoinWhenServerForgot() async throws {
        let defaults = UserDefaults(suiteName: "opto.lb.\(UUID())")!
        let fake = FakeService()
        let model = LeaderboardModel(defaults: defaults, service: { fake })
        XCTAssertFalse(model.isActive)
        try await model.join(name: " 小禾 ")
        XCTAssertTrue(model.joined)
        XCTAssertTrue(model.prompted)
        XCTAssertEqual(model.name, "小禾")
        XCTAssertEqual(model.board?.mine?.correct, 3)

        fake.serverJoined = false
        await model.refresh(flushFirst: false)
        XCTAssertEqual(fake.profiles.last?.1, true, "a remembered member is re-joined")
        XCTAssertNotNil(model.board?.mine)

        try await model.leave()
        XCTAssertFalse(model.joined)
        XCTAssertNil(model.board)
        XCTAssertEqual(fake.profiles.last?.1, false)

        defaults.set(true, forKey: LeaderboardModel.joinedKey)
        defaults.set(false, forKey: SettingsKey.usageLogEnabled)
        XCTAssertFalse(model.isActive, "turning 使用紀錄回傳 off switches the board off")

        do {
            try await model.join(name: "")
            XCTFail("empty name should throw")
        } catch let e as LeaderboardError { XCTAssertEqual(e, .invalidName) }
    }

    // MARK: 歷屆 figures

    @MainActor
    func testUnitHistoryCountsFictionalPaper() {
        let bank = QuestionBank.loadFromBundle(Bundle(for: QuestionBank.self))
        let table = UnitHistory.compute(bank: bank)
        XCTAssertEqual(table.sittings.map(\.label), ["999補"])
        XCTAssertEqual(table.rangeText, "999–999 年一般考試 1 場")
        let item = table.stat("視覺光學-demo")
        XCTAssertEqual(item.counts, [4])
        XCTAssertEqual(item.total, 4)
    }

    func testOnlyOptometristPapersEnterTheBank() {
        XCTAssertTrue(QuestionBank.isOptometristPaper(cls: "驗光師"))
        XCTAssertFalse(QuestionBank.isOptometristPaper(cls: "驗光生"))
        XCTAssertFalse(QuestionBank.isOptometristPaper(cls: nil))
    }

    // MARK: 錯題 definition

    private func q(_ id: String, unit: String = "視覺光學-1.4", year: Int = 115) -> Question {
        Question(id: id, code: "C\(year)", year: year, examKind: ExamKind.general, subject: "視覺光學", number: 1, stem: "測試",
                 options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A", corrected: false,
                 correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false, concepts: [unit])
    }

    @MainActor
    func testUnitMistakesAreTheOpenMistakeSet() throws {
        let container = StudyDataStore.makeContainer(inMemory: true, recovery: DataStoreRecovery(defaults: UserDefaults(suiteName: "opto.r15.\(UUID())")!))
        let context = container.mainContext
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        var store = StudyStore(context: context, scheduler: Scheduler(calendar: cal))
        store.usageSink = { _, _ in }
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 10))!
        let qs = ["wrong", "right", "guess", "parked", "mastered", "unseen", "old"].map { id in
            id == "old" ? q(id, year: 108) : q(id)
        }
        let byID = Dictionary(uniqueKeysWithValues: qs.map { ($0.id, $0) })
        store.commit(question: byID["wrong"]!, chosen: "B", correct: false, unsure: false, reason: nil, now: now)
        store.commit(question: byID["right"]!, chosen: "A", correct: true, unsure: false, reason: nil, now: now)
        store.commit(question: byID["guess"]!, chosen: "A", correct: true, unsure: true, reason: nil, now: now)
        store.commit(question: byID["parked"]!, chosen: "B", correct: false, unsure: false, reason: nil, now: now)
        store.park(questionID: "parked", now: now)
        store.commit(question: byID["mastered"]!, chosen: "B", correct: false, unsure: false, reason: nil, now: now)
        let rec = try XCTUnwrap(store.record(for: "mastered"))
        rec.schedule = ReviewSchedule(stability: 40, difficulty: 5, reps: 5, lapses: 1, lastReview: now,
                                      due: cal.date(byAdding: .day, value: 40, to: now), dueCorrectCount: 3)
        store.commit(question: byID["old"]!, chosen: "B", correct: false, unsure: false, reason: nil, now: now)
        try context.save()

        let history = store.practiceHistory(now: now)
        XCTAssertEqual(history.open, ["wrong", "guess", "old"], "same set as 自選練習 未熟練錯題 and the 錯題本 open list")
        let openRecords = Set(store.allRecords().filter { $0.isOpenMistake(using: store.scheduler, at: now) }.map(\.questionID))
        XCTAssertEqual(history.open, openRecords)

        let attempts = store.allAttempts().map { ($0.questionID, $0.correct) }
        let all = UnitProgress.compute(questions: qs, attempts: attempts, history: history)["視覺光學-1.4"]!
        XCTAssertEqual(all.questions, 7)
        XCTAssertEqual(all.seen, 6)
        XCTAssertEqual(all.unseen, 1)
        XCTAssertEqual(all.open, 3)
        XCTAssertEqual(all.answers, 6)
        XCTAssertEqual(all.correct, 2)
        XCTAssertEqual(all.percent, 33)

        // A year range narrows every figure to its questions.
        var range = YearSelection(mode: .range, from: 110, to: 115)
        range = range.normalized(years: [106, 115])
        let inRange = UnitProgress.compute(questions: qs.filter { range.contains($0.year) }, attempts: attempts, history: history)
        XCTAssertEqual(inRange["視覺光學-1.4"]?.open, 2)
        XCTAssertEqual(inRange["視覺光學-1.4"]?.answers, 5)
    }

    func testSectionsGroupConsecutiveChapters() {
        let units = [ConceptUnit(id: "a", subject: "s", name: "a", group: "隱形眼鏡學"),
                     ConceptUnit(id: "b", subject: "s", name: "b", group: "隱形眼鏡學"),
                     ConceptUnit(id: "c", subject: "s", name: "c", group: nil),
                     ConceptUnit(id: "d", subject: "s", name: "d", group: "配鏡學")]
        let sections = UnitProgress.sections(units)
        XCTAssertEqual(sections.map(\.title), ["隱形眼鏡學", nil, "配鏡學"])
        XCTAssertEqual(sections[0].units.map(\.id), ["a", "b"])
    }

    // MARK: Year filter persistence

    func testYearFilterIsSharedByUnitScreens() {
        let defaults = UserDefaults(suiteName: "opto.years.\(UUID())")!
        let range = YearSelection(mode: .range, from: 110, to: 115)
        YearFilterStore.set(range, for: .units, defaults: defaults)
        YearFilterStore.set(YearSelection(mode: .single, from: 112, to: 112), for: .subjectDetail, defaults: defaults)
        XCTAssertEqual(YearFilterStore.get(.units, defaults: defaults), range)
        XCTAssertEqual(YearFilterStore.get(.subjectDetail, defaults: defaults).label, "112 年")
        // 單元總覽 and 單元頁 both bind @AppStorage to this one raw string.
        XCTAssertEqual(YearFilterStore.decode(defaults.string(forKey: YearFilterStore.key(.units)) ?? ""), range)
        YearFilterStore.set(.all, for: .units, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: YearFilterStore.key(.units)))
        XCTAssertEqual(YearFilterStore.get(.units, defaults: defaults), .all)
        XCTAssertEqual(YearFilterStore.get(.subjectDetail, defaults: defaults).label, "112 年")
    }

    func testLegacyUnitYearFiltersMigrateFromOverview() {
        let defaults = UserDefaults(suiteName: "opto.years.\(UUID())")!
        let overview = YearSelection(mode: .single, from: 115, to: 115)
        defaults.set(ScopeStore.encode(overview), forKey: "yearFilter.unitOverview")
        defaults.set(ScopeStore.encode(YearSelection(mode: .range, from: 105, to: 108)), forKey: "yearFilter.unitDetail")
        YearFilterStore.migrateLegacy(defaults: defaults)
        XCTAssertEqual(YearFilterStore.get(.units, defaults: defaults), overview)
        XCTAssertNil(defaults.string(forKey: "yearFilter.unitOverview"))
        XCTAssertNil(defaults.string(forKey: "yearFilter.unitDetail"))
        // Idempotent; never overwrites a shared range already set.
        defaults.set(ScopeStore.encode(YearSelection(mode: .range, from: 110, to: 111)), forKey: "yearFilter.unitOverview")
        YearFilterStore.migrateLegacy(defaults: defaults)
        XCTAssertEqual(YearFilterStore.get(.units, defaults: defaults), overview)
    }

    // MARK: Upload back-off

    @MainActor
    func testRateLimitedUploadBacksOff() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r15-\(UUID())/usage-queue.jsonl")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var calls = 0
        var status = 429
        let device = UsageDevice(id: "12345678-1234-1234-1234-123456789012", name: "", model: "iPhone15,2", os: "26.1", app: "1")
        let log = UsageLog(config: AIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-only", fallbackBaseURLs: []),
                           defaults: UserDefaults(suiteName: "opto.backoff.\(UUID())")!, queueURL: url, device: device,
                           isTesting: false, isSimulator: false, arguments: [], now: { clock }) { _, _ in
            calls += 1
            return status
        }
        log.log("export")
        await log.flush()
        XCTAssertEqual(calls, 1)
        await log.flush()
        XCTAssertEqual(calls, 1, "no retry inside the back-off window")
        clock.addTimeInterval(UsageLog.rateLimitDelay - 1)
        await log.flush()
        XCTAssertEqual(calls, 1)
        clock.addTimeInterval(2)
        status = 200
        await log.flush()
        XCTAssertEqual(calls, 2)
        XCTAssertNil(log.retryAfter)
        XCTAssertTrue(try UsageEventQueue(url: url).events.isEmpty)
    }

    // MARK: 複習怎麼排 copy

    /// The 1、2、6、17 天 → 熟練 sequence on the onboarding page and in 設定 › 複習怎麼排.
    func testReviewGuideIntervalsMatchScheduler() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let s = Scheduler(calendar: cal)
        var now = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9))!
        var state = s.next(.unseen, outcome: .wrong, at: now)
        var intervals: [Int] = []
        for _ in 0..<5 {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: state.due!).day!
            intervals.append(days)
            XCTAssertFalse(s.isMastered(state, at: now), "not mastered before the 17-day review")
            now = state.due!.addingTimeInterval(9 * 3600)
            state = s.next(state, outcome: .correct, at: now)
            if intervals.count == 4 { break }
        }
        XCTAssertEqual(intervals, [1, 2, 6, 17])
        XCTAssertTrue(s.isMastered(state, at: now))
        // A first answer that is correct and not marked 猜的 is a 確認題 (A1): scheduled about 8 days out, not a mistake.
        let confirmation = s.next(.unseen, outcome: .correct, at: now)
        XCTAssertTrue(confirmation.isConfirmation)
        XCTAssertEqual(cal.dateComponents([.day], from: cal.startOfDay(for: now), to: confirmation.due!).day, 8)
        XCTAssertTrue(s.next(.unseen, outcome: .unsure, at: now).isScheduled)
        XCTAssertEqual(ExamDatePolicy.leadDays, 3)
        XCTAssertEqual(ExamDatePolicy.finalWindowDays, 14)
    }

    // MARK: AI explanation layout

    func testStructuredExplanationParsesAndFallsBack() {
        let text = """
        答案〔B〕：近視眼的遠點在眼前有限距離。

        為什麼
        ・遠點距離等於屈光度倒數。
        ・-4.00 D 的遠點在 25 cm。

        其他選項
        〔A〕錯：遠視眼才在眼後。
        〔C〕錯：單位錯。

        記憶點：近視看近清楚。
        """
        let mapped = AIOptionMarkers.map(text, order: OptionOrder(shown: ["C", "A", "D", "B"]))
        let s = AIStructuredExplanation.parse(mapped)
        XCTAssertEqual(s?.headline, "答案D：近視眼的遠點在眼前有限距離。")
        XCTAssertEqual(s?.reasons, ["遠點距離等於屈光度倒數。", "-4.00 D 的遠點在 25 cm。"])
        XCTAssertEqual(s?.others, ["B錯：遠視眼才在眼後。", "A錯：單位錯。"])
        XCTAssertEqual(s?.memory, "近視看近清楚。")

        XCTAssertNil(AIStructuredExplanation.parse("正確答案是 B。\n因為遠點在眼前。"), "old cached text stays plain")
        XCTAssertNil(AIStructuredExplanation.parse("答案〔B〕：重點。\n多出來的一行"), "unknown lines fall back")
        XCTAssertNil(AIStructuredExplanation.parse("答案〔B〕：只有標題"), "needs the 為什麼 list")
        let minimal = AIStructuredExplanation.parse("答案〔A〕：重點。\n為什麼\n・理由")
        XCTAssertEqual(minimal?.others, [])
        XCTAssertNil(minimal?.memory)
    }

    // MARK: 相關考古題

    private func rq(_ id: String, code: String = "P1", number: Int, stem: String, concepts: [String]) -> Question {
        Question(id: id, code: code, year: 115, examKind: ExamKind.general, subject: "視覺光學", number: number, stem: stem,
                 options: ["A": "甲", "B": "乙", "C": "丙", "D": "丁"], answer: ["A"], originalAnswer: "A", corrected: false,
                 correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false, concepts: concepts)
    }

    func testRelatedPrefersSamePrimaryUnitThenSharedUnitThenWording() {
        let target = rq("t", number: 1, stem: "稜鏡度與鏡片偏心距離的關係為何", concepts: ["U4"])
        // Nearly identical wording but another unit.
        let twin = rq("twin", code: "P2", number: 10, stem: "稜鏡度與鏡片偏心距離的關係為何", concepts: ["U9"])
        // Same primary unit, modest overlap.
        let same = rq("same", code: "P3", number: 10, stem: "鏡片偏心產生的稜鏡效應", concepts: ["U4"])
        // Shares only a secondary unit.
        let shared = rq("shared", code: "P4", number: 10, stem: "稜鏡度與鏡片偏心的單位定義", concepts: ["U2", "U4"])
        // Same unit but no wording overlap at all: still too weak to show.
        let unrelated = rq("none", code: "P5", number: 10, stem: "角膜弧度儀測量原理", concepts: ["U4"])
        // Same paper, adjacent number: skipped even though it matches.
        let neighbor = rq("near", number: 2, stem: "稜鏡度與鏡片偏心距離的關係為何", concepts: ["U4"])
        let index = RelatedIndex(questions: [target, twin, same, shared, unrelated, neighbor])
        XCTAssertEqual(index.related(to: "t"), ["same", "shared", "twin"])
        XCTAssertEqual(RelatedIndex(questions: [neighbor, unrelated, shared, same, twin, target]).related(to: "t"),
                       ["same", "shared", "twin"], "independent of input order")
    }

    // MARK: Segment order and practice size

    func testYearSegmentsPutAllLastAndDefaultToAll() {
        XCTAssertEqual(YearSelection.Mode.segmentOrder.map(\.label), ["單一年", "範圍", "全部"])
        XCTAssertEqual(YearSelection().mode, .all)
        XCTAssertEqual(UnitDetailView.Filter.allCases.last, .all)
    }

    func testPracticeSizeFollowsDailyGoalAndMapsOldFixedSizes() {
        var choice = CustomPracticeChoice()
        XCTAssertEqual(choice.size, CustomPracticeChoice.goalSize, "new choices use 每天想做幾題")
        XCTAssertFalse(choice.isCustomSize)
        XCTAssertEqual(choice.take(100, goal: 30), 30)
        XCTAssertEqual(choice.take(12, goal: 30), 12)
        choice.size = 0
        XCTAssertEqual(choice.take(100, goal: 30), 100, "全部")

        // Stored before 1.5: 20 with a goal of 20 becomes the goal option; 10 stays a 自訂 size.
        let old20 = CustomPracticeChoice(kind: .all, size: 20).normalized(goal: 20)
        XCTAssertEqual(old20.size, CustomPracticeChoice.goalSize)
        let old10 = CustomPracticeChoice(kind: .all, size: 10).normalized(goal: 20)
        XCTAssertEqual(old10.size, 10)
        XCTAssertTrue(old10.isCustomSize)
        let old20goal25 = CustomPracticeChoice(kind: .all, size: 20).normalized(goal: 25)
        XCTAssertEqual(old20goal25.size, 20)

        let pool = (1...40).map { q("p\($0)") }
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(CustomPractice.queue(pool: pool, choice: CustomPracticeChoice(kind: .all), history: .init(),
                                            goal: 25, using: &rng).count, 25)
    }

    // MARK: Leaderboard consent

    /// Board requests suspend until released, so a leave can land while refresh() is waiting.
    private final class GatedService: LeaderboardService {
        var serverJoined = false
        var failProfile = false
        var profiles: [Bool] = []
        var onBoard: (() async -> Void)?
        func board() async throws -> LeaderboardBoard {
            await onBoard?()
            return LeaderboardBoard(joined: serverJoined, week: nil, entries: serverJoined
                ? [LeaderboardEntry(id: "0123456789ab", name: "我", rank: 1, correct: 1, days: 1, accuracy: 1, me: true)] : [])
        }
        func setProfile(name: String, joined: Bool) async throws -> LeaderboardProfile {
            if failProfile { throw LeaderboardError.unreachable }
            profiles.append(joined)
            serverJoined = joined
            return LeaderboardProfile(id: "0123456789ab", name: name, joined: joined)
        }
        func member(id: String) async throws -> LeaderboardMember { throw LeaderboardError.notFound }
    }

    @MainActor
    func testLeaveDuringRefreshIsNeverUndoneByAutoRejoin() async throws {
        let defaults = UserDefaults(suiteName: "opto.lb.race.\(UUID())")!
        let fake = GatedService()
        let model = LeaderboardModel(defaults: defaults, service: { fake })
        try await model.join(name: "我")
        fake.serverJoined = false  // server forgot the profile
        fake.onBoard = { [weak model] in
            fake.onBoard = nil
            try? await model?.leave()  // the user leaves while the board request is in flight
        }
        await model.refresh(flushFirst: false)
        XCTAssertFalse(model.joined)
        XCTAssertNil(model.board)
        XCTAssertFalse(fake.serverJoined, "no silent re-join after leaving")
        XCTAssertFalse(fake.profiles.dropFirst().contains(true))

        // Same for 使用紀錄回傳 turned off mid-request.
        try await model.join(name: "我")
        fake.serverJoined = false
        fake.onBoard = { fake.onBoard = nil; defaults.set(false, forKey: SettingsKey.usageLogEnabled) }
        let before = fake.profiles.count
        await model.refresh(flushFirst: false)
        XCTAssertNil(model.board)
        XCTAssertEqual(fake.profiles.count, before, "no re-join once usage is off")
    }

    @MainActor
    func testFailedLeaveStaysPendingUntilServerConfirms() async throws {
        let defaults = UserDefaults(suiteName: "opto.lb.leave.\(UUID())")!
        let fake = GatedService()
        let model = LeaderboardModel(defaults: defaults, service: { fake })
        try await model.join(name: "我")
        fake.failProfile = true
        do { try await model.leave(); XCTFail("offline leave should throw") } catch {}
        XCTAssertFalse(model.joined)
        XCTAssertTrue(model.pendingLeave)
        XCTAssertTrue(fake.serverJoined, "the server still lists the user")

        await model.retryPendingLeave()
        XCTAssertTrue(model.pendingLeave, "still pending while offline")
        fake.failProfile = false
        await model.refresh(flushFirst: false)
        XCTAssertFalse(model.pendingLeave)
        XCTAssertFalse(fake.serverJoined)
        XCTAssertEqual(fake.profiles.last, false)

        // Joining again clears any pending leave.
        defaults.set(true, forKey: LeaderboardModel.pendingLeaveKey)
        try await model.join(name: "我")
        XCTAssertFalse(model.pendingLeave)
    }
}
