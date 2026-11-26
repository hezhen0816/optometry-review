import XCTest
@testable import OptometryReview

final class QuestionBankTests: XCTestCase {
    func testFictionalPaperLoadsFromTheAppBundle() throws {
        let bank = QuestionBank.loadFromBundle(Bundle(for: QuestionBank.self))
        let paper = try XCTUnwrap(bank.paperByID[Paper.makeID(code: "999001", subject: "視覺光學")])
        XCTAssertEqual(bank.questions(of: paper).count, 4)
        XCTAssertEqual(bank.byID.count, bank.questions.count, "question ids must be unique")
        XCTAssertEqual(bank.reviewPool(includeSpecial: false).map(\.id), paper.questionIDs)
        XCTAssertTrue(bank.hasCorrection(paper))
        XCTAssertNil(bank.pdfURL(paper, .questions))

        let corrected = try XCTUnwrap(bank.byID[paper.questionIDs[0]])
        XCTAssertEqual(corrected.originalAnswer, "B")
        XCTAssertEqual(corrected.answer, ["C"])
        XCTAssertTrue(corrected.corrected)
    }
}
