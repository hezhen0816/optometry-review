import XCTest
import SwiftData
@testable import OptometryReview

/// 學習版第二批: chosen letter in usage events, insight freshness and ordering, 檢討這回 grouping, tolerant decoding.
final class WeakAnalysisTests: XCTestCase {
    private func question(_ id: String) -> Question {
        Question(id: id, code: "115100", year: 115, examKind: ExamKind.general, subject: Subjects.all[1], number: 1,
                 stem: "s", options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A",
                 corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
    }

    // MARK: chosen in usage events

    @MainActor
    func testAnswerEventCarriesOriginalLetterUnderShuffle() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var events: [(String, [String: Any])] = []
        let store = StudyStore(context: container.mainContext, usageSink: { events.append(($0, $1)) })
        // Shown order C A D B: the learner taps the second row (displayed "B"), which is the ORIGINAL option A.
        let order = OptionOrder(shown: ["C", "A", "D", "B"])
        let tapped = order.originalLetter(forDisplayed: "B")
        XCTAssertEqual(tapped, "A")
        let wrongTap = order.originalLetter(forDisplayed: "A")
        XCTAssertEqual(wrongTap, "C")
        store.commit(question: question("q1"), chosen: wrongTap, correct: false, unsure: false, reason: nil)
        XCTAssertEqual(events.last?.1["chosen"] as? String, "C")
        store.commit(question: question("q2"), chosen: tapped, correct: true, unsure: true, reason: nil)
        XCTAssertEqual(events.last?.1["chosen"] as? String, "A")
        // 「看解答」 sends no chosen.
        store.commit(question: question("q3"), chosen: "", correct: false, unsure: false, reason: nil, revealed: true)
        XCTAssertEqual(events.last?.0, "answer")
        XCTAssertNil(events.last?.1["chosen"])
    }

    // MARK: freshness and ordering

    private func stat(_ id: String, _ label: PointLabel, open: Int = 1, questions: Int = 5) -> PointStat {
        PointStat(point: StudyPoint(id: id, unitID: "U", number: 1, title: id, summary: ""),
                  questions: questions, answers: 2, wrong: 1, open: open, done: 1, label: label)
    }

    private func snapshot(hoursAgo: Double, focus: [String], now: Date) -> InsightsSnapshot {
        InsightsSnapshot(generatedAt: now.addingTimeInterval(-hoursAgo * 3600), focus: focus,
                         notes: Dictionary(uniqueKeysWithValues: focus.map { ($0, InsightNote(misconception: "m", fix: "f", reason: "理由 \($0)")) }),
                         fetchedAt: now)
    }

    func testFreshnessWindowIsThirtySixHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(snapshot(hoursAgo: 35.9, focus: [], now: now).isFresh(now: now))
        XCTAssertTrue(snapshot(hoursAgo: 36, focus: [], now: now).isFresh(now: now))
        XCTAssertFalse(snapshot(hoursAgo: 36.1, focus: [], now: now).isFresh(now: now))
        // Without a usable generatedAt the download time counts.
        let undated = InsightsSnapshot(generatedAt: nil, focus: [], notes: [:], fetchedAt: now.addingTimeInterval(-40 * 3600))
        XCTAssertFalse(undated.isFresh(now: now))
    }

    func testTodayUsesFreshFocusOrderWithReasonsAndFillsFromRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stats = [stat("U#1", .needsWork, open: 3), stat("U#2", .needsWork, open: 2),
                     stat("U#3", .shaky), stat("U#4", .steady), stat("U#5", .shaky, open: 2)]
        // The analysis puts U#3 first; U#4 is steady now and is skipped; unknown ids are skipped.
        let snap = snapshot(hoursAgo: 5, focus: ["U#3", "U#4", "U#9", "U#2"], now: now)
        let rows = WeakPointRanking.today(stats: stats, snapshot: snap, limit: 3, now: now)
        XCTAssertEqual(rows.map(\.stat.point.id), ["U#3", "U#2", "U#1"])
        XCTAssertEqual(rows.map(\.reason), ["理由 U#3", "理由 U#2", nil])
    }

    func testTodayFallsBackToRulesWhenStaleOrMissing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stats = [stat("U#1", .shaky), stat("U#2", .needsWork, open: 2), stat("U#3", .needsWork, open: 3)]
        let rules = PointMastery.weakest(stats, limit: 3).map(\.point.id)
        XCTAssertEqual(rules, ["U#3", "U#2", "U#1"])
        for snap in [snapshot(hoursAgo: 40, focus: ["U#1"], now: now), nil] {
            let rows = WeakPointRanking.today(stats: stats, snapshot: snap, limit: 3, now: now)
            XCTAssertEqual(rows.map(\.stat.point.id), rules)
            XCTAssertTrue(rows.allSatisfy { $0.reason == nil })
        }
    }

    @MainActor
    func testStoreKeepsSnapshotAndThrottlesFetches() throws {
        let defaults = UserDefaults(suiteName: "opto.insights.\(UUID())")!
        let store = InsightsStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(store.fresh(now: now))
        store.set(snapshot(hoursAgo: 1, focus: ["U#1"], now: now))
        XCTAssertEqual(InsightsStore(defaults: defaults).snapshot?.focus, ["U#1"])
        XCTAssertEqual(InsightsStore(defaults: defaults).note(for: "U#1")?.reason, "理由 U#1")
        XCTAssertNotNil(store.fresh(now: now))
        XCTAssertNil(store.fresh(now: now.addingTimeInterval(40 * 3600)))
        XCTAssertTrue(store.canFetch(now: now))
        defaults.set([now.timeIntervalSince1970], forKey: InsightsStore.fetchLogKey)
        XCTAssertFalse(store.canFetch(now: now.addingTimeInterval(600)))
        XCTAssertTrue(store.canFetch(now: now.addingTimeInterval(3700)))
        defaults.set((0..<4).map { now.timeIntervalSince1970 - Double($0) * 7200 }, forKey: InsightsStore.fetchLogKey)
        XCTAssertFalse(store.canFetch(now: now.addingTimeInterval(1)))
        XCTAssertTrue(store.canFetch(now: now.addingTimeInterval(25 * 3600)))
    }

    // MARK: 檢討這回 grouping

    func testReviewGroupingByPointWithFirstAnswersAndCovered() {
        let log = [RoundAnswer(qid: "a", chosen: "B", correct: false, unsure: false),
                   RoundAnswer(qid: "b", chosen: "A", correct: true, unsure: false),
                   RoundAnswer(qid: "a", chosen: "A", correct: true, unsure: false),   // the retry of a: ignored
                   RoundAnswer(qid: "c", chosen: "A", correct: true, unsure: true),
                   RoundAnswer(qid: "d", chosen: "", correct: false, unsure: false),
                   RoundAnswer(qid: "e", chosen: "C", correct: false, unsure: false)]
        let first = RoundReview.firstAnswers(log)
        XCTAssertEqual(first.map(\.qid), ["a", "b", "c", "d", "e"])
        let flagged = RoundReview.flagged(first)
        XCTAssertEqual(flagged.map(\.qid), ["a", "c", "d", "e"])
        let tags = ["a": ["P#1"], "c": ["P#2", "P#1"], "d": ["P#2"]]
        // c has two tags: without coverage info the first one (P#2) wins; with P#1 covered it goes there.
        var groups = RoundReview.group(flagged, pointsOfQuestion: tags)
        XCTAssertEqual(groups.map(\.pointID), ["P#2", "P#1", ""])
        XCTAssertEqual(groups.map { $0.items.map(\.answer.qid) }, [["c", "d"], ["a"], ["e"]])
        groups = RoundReview.group(flagged, pointsOfQuestion: tags, covered: ["P#1"])
        XCTAssertEqual(groups.map(\.pointID), ["P#1", "P#2", ""])
        XCTAssertEqual(groups[0].items.map(\.answer.qid), ["a", "c"])
        // The server gets the round as plain JSON objects.
        XCTAssertEqual(log[0].jsonObject["chosen"] as? String, "B")
        XCTAssertEqual(log[3].jsonObject["unsure"] as? Bool, true)
    }

    func testReviewKeepsGroupsTheServerDidNotReturn() {
        let flagged = [RoundAnswer(qid: "a", chosen: "B", correct: false, unsure: false),
                       RoundAnswer(qid: "b", chosen: "C", correct: false, unsure: false),
                       RoundAnswer(qid: "c", chosen: "A", correct: false, unsure: false)]
        let tags = ["a": ["P#1"], "b": ["P#2", "P#1"], "c": ["P#3"]]
        // The server explained P#1 only: b (also tagged P#1) belongs to that group, so only c is left over.
        let rest = RoundReview.group(flagged, pointsOfQuestion: tags, covered: ["P#1"])
        let left = RoundReview.notServed(rest, servedPointIDs: ["P#1"])
        XCTAssertEqual(left.map(\.pointID), ["P#3"])
        XCTAssertEqual(left[0].items.map(\.answer.qid), ["c"])
    }

    // MARK: Decoding tolerance

    func testInsightsDecodeToleratesMissingAndOddFields() throws {
        let json = """
        {"generatedAt":"2026-10-11T03:05:00+08:00","focus":["U#1",2],
         "notes":{"U#1":{"misconception":"搞混 A","fix":"- 一\\n- 二","reason":"3 次","refs":["115100_0902_5",7],"extra":1},
                  "U#2":{"fix":"只有補救"},
                  "U#3":"not an object",
                  "U#4":{},
                  "U#5":{"misconception":"m","refs":[7,8]}},
         "unknownKey":true}
        """
        let s = try JSONDecoder().decode(InsightsSnapshot.self, from: Data(json.utf8))
        XCTAssertNotNil(s.generatedAt)
        XCTAssertEqual(s.focus, [])           // a mixed array is dropped as a whole, not a crash
        XCTAssertEqual(Set(s.notes.keys), ["U#1", "U#2", "U#5"])
        XCTAssertEqual(s.notes["U#1"]?.refs, [])    // a mixed array is dropped as a whole
        XCTAssertEqual(s.notes["U#5"]?.refs, ["7", "8"])
        XCTAssertEqual(s.notes["U#1"]?.fix, "- 一\n- 二")
        XCTAssertEqual(s.notes["U#2"]?.misconception, "")
        XCTAssertEqual(s.notes["U#1"]?.at, s.generatedAt)
        let empty = try JSONDecoder().decode(InsightsSnapshot.self, from: Data("{}".utf8))
        XCTAssertNil(empty.generatedAt)
        XCTAssertTrue(empty.notes.isEmpty)
        // Epoch seconds and milliseconds both parse.
        XCTAssertEqual(Wire.parseDate(1_800_000_000.0), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(Wire.parseDate(1_800_000_000_000.0), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(Wire.parseDate("yesterday"))
    }

    func testSnapshotRoundTripsThroughStorage() throws {
        let s = snapshot(hoursAgo: 2, focus: ["U#1"], now: Date(timeIntervalSince1970: 1_800_000_000))
        let back = try JSONDecoder().decode(InsightsSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.focus, s.focus)
        XCTAssertEqual(back.notes["U#1"]?.reason, "理由 U#1")
        XCTAssertEqual(back.generatedAt?.timeIntervalSince1970 ?? 0, s.generatedAt!.timeIntervalSince1970, accuracy: 1)
    }

    func testReviewResultDecodesServerGroups() throws {
        let json = """
        {"generatedAt":"2026-10-11T10:00:00Z","groups":[
          {"pointId":"U#2","unit":"U","title":"考點二",
           "note":{"misconception":"m2","fix":"f2","reason":"r2","refs":["q1"]},
           "questions":[{"qid":"q1","chosen":"C","correct":false,"unsure":false,"answer":["B"],"line":"你選 C：把 X 當成 Y"},
                        {"qid":"q2","chosen":null,"correct":false,"unsure":false,"answer":["A"]}]},
          {"pointId":"U#1","title":"考點一","note":null,"questions":[]},
          {"title":"no id"}]}
        """
        let r = try XCTUnwrap(ReviewResult.decode(Data(json.utf8)))
        XCTAssertEqual(r.groups.map(\.pointID), ["U#2", "U#1"])
        XCTAssertEqual(r.groups[0].note?.misconception, "m2")
        XCTAssertNotNil(r.groups[0].note?.at)
        XCTAssertEqual(r.groups[0].questions.map(\.line), ["你選 C：把 X 當成 Y", ""])
        XCTAssertEqual(r.groups[0].questions[1].chosen, "")
        XCTAssertEqual(r.groups[0].questions[0].answer, ["B"])
        XCTAssertNil(r.groups[1].note)
        XCTAssertEqual(r.notes.keys.sorted(), ["U#2"])
        XCTAssertNil(ReviewResult.decode(Data("[1,2]".utf8)))
        XCTAssertEqual(ReviewResult.decode(Data("{\"groups\":[]}".utf8))?.groups.count, 0)
    }

    func testReviewErrorsMapToPlainMessages() {
        func body(_ e: String) -> Data { Data("{\"error\":\"\(e)\"}".utf8) }
        XCTAssertEqual(WeakAnalysisError.map(status: 429, body: body("monthly budget reached")), .budget)
        XCTAssertEqual(WeakAnalysisError.map(status: 429, body: body("rate limited")), .ai(.rateLimited))
        XCTAssertEqual(WeakAnalysisError.map(status: 503, body: body("bank unavailable")), .unavailable)
        XCTAssertEqual(WeakAnalysisError.map(status: 502, body: body("all groups failed")), .ai(.generationFailed))
        XCTAssertEqual(WeakAnalysisError.map(status: 400, body: Data()), .badRequest)
        XCTAssertEqual(WeakAnalysisError.map(status: 403, body: body("blocked")), .ai(.blocked))
        XCTAssertTrue(WeakAnalysisError.offline.message.contains("網路"))
        XCTAssertFalse(WeakAnalysisError.budget.retryable)
    }

    @MainActor
    func testMergeStoresReviewNotesForTheHandout() throws {
        let store = InsightsStore(defaults: UserDefaults(suiteName: "opto.merge.\(UUID())")!)
        let note = InsightNote(misconception: "m", fix: "f", reason: "r", refs: [], questionNotes: [:], at: nil)
        store.merge(ReviewResult(generatedAt: nil, groups: [
            ReviewResultGroup(pointID: "U#1", title: "t", note: note, questions: []),
            ReviewResultGroup(pointID: "U#2", title: "t", note: nil, questions: [])]))
        XCTAssertEqual(store.note(for: "U#1")?.fix, "f")
        XCTAssertNil(store.note(for: "U#2"))
        // Merging notes does not make an old analysis look fresh.
        XCTAssertNil(store.fresh())
    }

    func testChosenNoteLetterFollowsShownOrder() {
        let order = OptionOrder(shown: ["C", "A", "D", "B"])
        // Original C is shown as "A"; the original-letter marker 〔A〕 is shown as "B".
        XCTAssertEqual(ChosenNoteText.display("你選了 C：把分子當成分母", order: order), "你選了 A：把分子當成分母")
        XCTAssertEqual(ChosenNoteText.display("你選了〔C〕：與〔A〕混淆", order: order), "你選了 A：與B混淆")
        XCTAssertEqual(ChosenNoteText.display("你選了 C：x", order: .original), "你選了 C：x")
    }

    func testFixLinesBecomeBulletsAndTablesStayReadable() {
        let lines = InlineMarkdown.lines("先看**定義**\n- 要點一\n* 要點二\n1. 步驟\n| 甲 | 乙 |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(lines.map(\.text), ["先看**定義**", "要點一", "要點二", "步驟", "甲 ｜ 乙", "1 ｜ 2"])
        XCTAssertEqual(lines.map(\.bullet), [false, true, true, true, false, false])
    }
}
