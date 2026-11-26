import XCTest
@testable import OptometryReview

/// 0.2.1: 前題 stems, round completion numbers, small-sample unit accuracy.
final class Release021Tests: XCTestCase {

    // MARK: 前題

    func testSplitsSinglePremise() throws {
        let stem = "【前題】月球郵局的值班機器人（型號 L-7）     ，需要準備幾張郵票？（前題答案：三張）\n承上題，寄出一張後還有幾張？"
        let split = try XCTUnwrap(StemLayout.splitPremise(stem))
        XCTAssertEqual(split.premises, [.init(text: "月球郵局的值班機器人（型號 L-7），需要準備幾張郵票？",
                                              answer: "三張")])
        XCTAssertEqual(split.question, "承上題，寄出一張後還有幾張？")
    }

    func testKeepsParenthesesBeforeTheAnswer() throws {
        let stem = "【前題】水晶蝸牛收到了幾封信？（只計紙本）（前題答案：四封）\n承上題，再寄出兩封後還有幾封？（只計紙本）"
        let split = try XCTUnwrap(StemLayout.splitPremise(stem))
        XCTAssertEqual(split.premises.first?.text, "水晶蝸牛收到了幾封信？（只計紙本）")
        XCTAssertEqual(split.premises.first?.answer, "四封")
        XCTAssertEqual(split.question, "承上題，再寄出兩封後還有幾封？（只計紙本）")
    }

    func testSplitsChainedPremises() throws {
        let stem = "【前題】星港燈塔的燈由誰維護？（前題答案：值班機器人）\n"
            + "【前題】承上題，值班機器人帶了哪一盒工具？（前題答案：藍盒）\n"
            + "承上題，藍盒中有哪些工具？①螺絲起子 ②扳手"
        let split = try XCTUnwrap(StemLayout.splitPremise(stem))
        XCTAssertEqual(split.premises.map(\.answer), ["值班機器人", "藍盒"])
        XCTAssertEqual(split.premises[1].text, "承上題，值班機器人帶了哪一盒工具？")
        XCTAssertTrue(split.question.hasPrefix("承上題，藍盒中"))
    }

    func testFallsBackForOtherShapes() {
        XCTAssertNil(StemLayout.splitPremise("一般題目，沒有前題？"))
        // No line break before the question.
        XCTAssertNil(StemLayout.splitPremise("【前題】某題？（前題答案：A）承上題，下一題？"))
        // Premise without its answer.
        XCTAssertNil(StemLayout.splitPremise("【前題】某題？\n承上題，下一題？"))
        // Nothing after the premise.
        XCTAssertNil(StemLayout.splitPremise("【前題】某題？（前題答案：A）\n"))
        // Last line is itself a premise.
        XCTAssertNil(StemLayout.splitPremise("【前題】某題？（前題答案：A）\n【前題】下一題？（前題答案：B）"))
    }

    /// Every 前題 stem in the bundled bank splits.
    func testEveryBankPremiseStemSplits() {
        let premiseStems = QuestionBank.loadFromBundle(Bundle(for: QuestionBank.self)).questions.map(\.stem).filter { $0.hasPrefix(StemLayout.premiseTag) }
        XCTAssertFalse(premiseStems.isEmpty)
        for stem in premiseStems {
            XCTAssertNotNil(StemLayout.splitPremise(stem), stem)
        }
    }

    // MARK: Round completion

    func testRoundCountsQuestionsNotAttempts() {
        var r = RoundSummary()
        r.record("a", correct: true)
        r.record("b", correct: false)
        r.record("c", correct: false)
        r.record("b", correct: true)   // 再練一次
        r.record("c", correct: false)  // 再練一次, still wrong
        r.record("c", correct: true)
        XCTAssertEqual(r.practiced, 3)
        XCTAssertEqual(r.recovered, 2)
        XCTAssertEqual(r.stillWrong, 0)
        XCTAssertEqual(r.lines(retries: true), ["練了 3 題", "其中 2 題答錯後再練到答對"])
    }

    func testRoundStillWrongAtEnd() {
        var r = RoundSummary()
        r.record("a", correct: true)
        r.record("b", correct: false)  // moved out of review, never comes back
        XCTAssertEqual(r.lines(retries: true), ["練了 2 題", "1 題這輪沒有答對"])
        // Correct first, wrong later is still wrong at the end and not recovered.
        var s = RoundSummary()
        s.record("x", correct: true)
        s.record("x", correct: false)
        XCTAssertEqual(s.recovered, 0)
        XCTAssertEqual(s.stillWrong, 1)
    }

    func testRoundWithoutRetries() {
        var r = RoundSummary()
        r.record("a", correct: true)
        r.record("b", correct: false)
        XCTAssertEqual(r.lines(retries: false), ["練了 2 題", "其中 1 題答錯"])
        var all = RoundSummary()
        all.record("a", correct: true)
        XCTAssertEqual(all.lines(retries: false), ["練了 1 題"])
    }

    func testGoalLeft() {
        XCTAssertEqual(RoundSummary.goalLeft(correctToday: 19, goal: 20), 1)
        XCTAssertEqual(RoundSummary.goalLeft(correctToday: 25, goal: 20), 0)
        XCTAssertNil(RoundSummary.goalLeft(correctToday: 3, goal: 0))
    }

    // MARK: Small-sample accuracy

    func testSmallSampleShowsCounts() {
        XCTAssertEqual(UnitProgress.Row().accuracyText, "—")
        let one = UnitProgress.Row(questions: 3, seen: 1, correct: 1, answers: 1, open: 0)
        XCTAssertTrue(one.isSmallSample)
        XCTAssertEqual(one.accuracyText, "1/1")
        let low = UnitProgress.Row(questions: 3, seen: 2, correct: 0, answers: 4, open: 2)
        XCTAssertEqual(low.accuracyText, "0/4")
        XCTAssertFalse(low.isWeak, "too few answers to call a unit weak")
        let enough = UnitProgress.Row(questions: 9, seen: 5, correct: 2, answers: 5, open: 3)
        XCTAssertFalse(enough.isSmallSample)
        XCTAssertEqual(enough.accuracyText, "40%")
        XCTAssertTrue(enough.isWeak)
    }
}
