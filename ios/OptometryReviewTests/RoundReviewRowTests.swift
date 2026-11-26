import XCTest
@testable import OptometryReview

/// 0.3.0: 檢討這回 rows show option text instead of original-paper letters.
final class RoundReviewRowTests: XCTestCase {

    // MARK: 檢討這回 rows

    private func question(options: [String: String], answer: [String] = ["B"], allCredit: Bool = false) -> Question {
        Question(id: "t", code: "115100", year: 115, examKind: "一般", subject: "視光學", number: 4,
                 stem: "stem", options: options, answer: answer, originalAnswer: answer.first, corrected: false,
                 correctionNote: nil, allCredit: allCredit, hasFigure: false, needsReview: false)
    }

    func testRowShowsOptionTextNotLetters() {
        let q = question(options: ["A": "近視", "B": "遠視", "C": "散光", "D": "老花"])
        XCTAssertEqual(RowText.lines(question: q, chosen: "C", correct: false, answer: []), ["你選：散光", "答案：遠視"])
        XCTAssertEqual(RowText.lines(question: q, chosen: "B", correct: true, answer: ["B"]), ["你選：遠視（答對但猜的）"])
        XCTAssertEqual(RowText.lines(question: q, chosen: "", correct: false, answer: []), ["看解答", "答案：遠視"])
    }

    func testRowTruncatesLongAndImageOptions() {
        let long = String(repeating: "長", count: 40)
        let q = question(options: ["A": long, "B": "  ", "C": "c", "D": "d"], answer: ["A", "B"])
        let lines = RowText.lines(question: q, chosen: "C", correct: false, answer: [])
        XCTAssertEqual(lines[1], "答案：" + String(repeating: "長", count: RowText.limit) + "…；圖片選項")
        let credit = question(options: ["A": "a", "B": "b", "C": "c", "D": "d"], allCredit: true)
        XCTAssertEqual(RowText.lines(question: credit, chosen: "A", correct: false, answer: [])[1], "答案：一律給分")
    }
}
