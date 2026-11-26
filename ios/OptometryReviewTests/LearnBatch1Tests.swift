import XCTest
@testable import OptometryReview

final class LearnBatch1Tests: XCTestCase {
    private static let bank = QuestionBank.loadFromBundle(Bundle(for: QuestionBank.self))

    func testPointsLoadAndEveryQuestionHasOne() {
        let bank = Self.bank
        XCTAssertEqual(bank.learning.pointCount, 1)
        XCTAssertEqual(bank.learning.pointsByUnit.count, 1)
        let untagged = bank.questions.filter { (bank.learning.pointsOfQuestion[$0.id] ?? []).isEmpty }
        XCTAssertTrue(untagged.isEmpty, "untagged: \(untagged.prefix(3).map(\.id))")
        XCTAssertTrue(bank.learning.pointsOfQuestion.values.allSatisfy { (1...2).contains($0.count) })
        XCTAssertEqual(bank.allPoints.count, 1, "every point belongs to a syllabus unit")
        XCTAssertEqual(bank.learning.handouts.count, 1)
    }

    func testEveryHandoutRefResolvesToAQuestion() {
        let bank = Self.bank
        var total = 0
        for h in bank.learning.handouts.values {
            for (ref, id) in h.refs {
                total += 1
                XCTAssertNotNil(bank.byID[id], "\(h.unit): \(ref) → \(id)")
            }
            XCTAssertEqual(h.points.map(\.id), bank.learning.points(of: h.unit).map(\.id), "\(h.unit) points match 考點.json")
        }
        XCTAssertEqual(total, 1)
    }

    func testHandoutTextRefsAllHaveALink() {
        for h in Self.bank.learning.handouts.values {
            func check(_ text: String) {
                for ref in HandoutRefs.all(in: text) { XCTAssertNotNil(h.refs[ref], "\(h.unit): \(ref)") }
            }
            func walk(_ blocks: [HandoutBlock]) {
                for b in blocks {
                    switch b {
                    case .paragraph(let t): check(t)
                    case .list(_, let items):
                        func items_(_ list: [HandoutItem]) { for i in list { check(i.text); items_(i.children ?? []) } }
                        items_(items)
                    case .table(_, let rows): rows.joined().forEach(check)
                    default: break
                    }
                }
            }
            walk(h.intro); h.points.forEach { walk($0.blocks) }; h.extras.forEach { walk($0.blocks) }
        }
    }

    func testRefSplittingKeepsInlineTextAndPullsTrailingRefs() {
        let a = HandoutRefs.splitTrailing("錯的說法。（108110 #1）")
        XCTAssertEqual(a.body, "錯的說法。")
        XCTAssertEqual(a.refs, ["108110 #1"])
        let b = HandoutRefs.splitTrailing("代表題：106060 #1、106110 #2")
        XCTAssertEqual(b.body, "代表題：")
        XCTAssertEqual(b.refs, ["106060 #1", "106110 #2"])
        let c = HandoutRefs.splitTrailing("先看 106060 #1 再看別的")
        XCTAssertEqual(c.body, "先看 106060 #1 再看別的")
        XCTAssertTrue(c.refs.isEmpty)
    }

    func testQuizItemsSplitAtArrow() throws {
        let h = try XCTUnwrap(Self.bank.learning.handouts.values.first)
        XCTAssertFalse(h.quizItems.isEmpty)
        XCTAssertTrue(h.quizItems.allSatisfy { !$0.question.isEmpty && !$0.answer.isEmpty })
    }

    // MARK: Labels

    private func label(_ answers: Int, _ wrong: Int, open: Int, done: Int, unsure: Bool = false) -> PointLabel {
        PointMastery.label(answers: answers, wrong: wrong, open: open, done: done, lastCorrectButUnsure: unsure)
    }

    func testLabelBoundaries() {
        XCTAssertEqual(label(0, 0, open: 0, done: 0), .untouched)
        // 待加強: open >= 2, or answers >= 3 with wrong/answers >= 0.5
        XCTAssertEqual(label(2, 2, open: 2, done: 2), .needsWork)
        XCTAssertEqual(label(5, 1, open: 1, done: 5), .shaky, "one open mistake is only 還不穩")
        XCTAssertEqual(label(3, 2, open: 0, done: 3), .needsWork)
        XCTAssertEqual(label(4, 2, open: 0, done: 4), .needsWork, "exactly half wrong")
        XCTAssertEqual(label(5, 2, open: 0, done: 5), .steady, "below half wrong")
        XCTAssertEqual(label(2, 2, open: 0, done: 2), .shaky, "under 3 answers the ratio rule does not apply")
        // 還不穩: open == 1, last answer right but unsure, or fewer than 3 questions done
        XCTAssertEqual(label(2, 0, open: 0, done: 2), .shaky)
        XCTAssertEqual(label(6, 0, open: 0, done: 3, unsure: true), .shaky)
        XCTAssertEqual(label(3, 0, open: 0, done: 3), .steady)
        XCTAssertEqual(label(6, 1, open: 0, done: 3), .steady)
    }

    func testComputeCountsAnswersWrongOpenAndUnsure() {
        let p = StudyPoint(id: "U#1", unitID: "U", number: 1, title: "t", summary: "")
        let attempts = [
            PointMastery.Attempt(questionID: "a", correct: false, unsure: false),
            PointMastery.Attempt(questionID: "a", correct: true, unsure: false),
            PointMastery.Attempt(questionID: "b", correct: true, unsure: false),
            PointMastery.Attempt(questionID: "c", correct: true, unsure: true),
            PointMastery.Attempt(questionID: "z", correct: false, unsure: false), // outside the scope
        ]
        let stats = PointMastery.compute(points: [p], scope: ["a", "b", "c", "d"],
                                         questionsOfPoint: ["U#1": ["a", "b", "c", "d", "z"]],
                                         attempts: attempts, open: ["a"])
        let s = stats["U#1"]!
        XCTAssertEqual([s.questions, s.answers, s.wrong, s.open, s.done], [4, 4, 1, 1, 3])
        XCTAssertEqual(s.label, .shaky)
        XCTAssertEqual(s.countsText, "錯 1／做 4")
    }

    // MARK: 最該補

    private func stat(_ id: String, _ label: PointLabel, open: Int, questions: Int) -> PointStat {
        PointStat(point: StudyPoint(id: id, unitID: "U", number: 1, title: id, summary: ""),
                  questions: questions, answers: 1, wrong: 0, open: open, done: 1, label: label)
    }

    func testAnsweredByWeaknessDropsUntouchedAndKeepsAllLevels() {
        let all = [
            stat("U#1", .steady, open: 0, questions: 30),
            stat("U#2", .untouched, open: 0, questions: 40),
            stat("U#3", .shaky, open: 1, questions: 5),
            stat("U#5", .needsWork, open: 2, questions: 3),
            stat("U#6", .needsWork, open: 3, questions: 2),
            stat("U#9", .steady, open: 0, questions: 40),
        ]
        XCTAssertEqual(PointMastery.answeredByWeakness(all).map(\.id), ["U#6", "U#5", "U#3", "U#9", "U#1"])
    }

    func testWeakestOrderingAndCaps() {
        let all = [
            stat("U#1", .steady, open: 0, questions: 30),
            stat("U#2", .untouched, open: 0, questions: 40),
            stat("U#3", .shaky, open: 1, questions: 5),
            stat("U#4", .shaky, open: 1, questions: 12),
            stat("U#5", .needsWork, open: 2, questions: 3),
            stat("U#6", .needsWork, open: 3, questions: 2),
            stat("U#7", .needsWork, open: 2, questions: 9),
            stat("U#8", .shaky, open: 0, questions: 50),
        ]
        let top = PointMastery.weakest(all, limit: 10).map(\.id)
        XCTAssertEqual(top, ["U#6", "U#7", "U#5", "U#4", "U#3", "U#8"], "待加強 first, then 未熟 desc, then 歷屆題數 desc")
        XCTAssertEqual(PointMastery.weakest(all, limit: PointMastery.todayLimit).count, 3)
        XCTAssertEqual(PointMastery.weakest(all, limit: PointMastery.statsLimit).count, 5)
        XCTAssertTrue(PointMastery.weakest(Array(all.prefix(2)), limit: 3).isEmpty, "nothing weak hides the card")
    }
}
