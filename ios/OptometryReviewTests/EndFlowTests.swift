import XCTest
@testable import OptometryReview

/// 0.3.0 end-of-round flow: stem layout of fill-in-the-blank stems.
final class EndFlowTests: XCTestCase {

    // MARK: Goal page

    func testReachedGoalOnlyOnTheCrossingAnswer() {
        XCTAssertTrue(RoundSummary.reachedGoal(before: 9, after: 10, goal: 10))
        XCTAssertFalse(RoundSummary.reachedGoal(before: 10, after: 11, goal: 10))
        XCTAssertFalse(RoundSummary.reachedGoal(before: 8, after: 9, goal: 10))
        XCTAssertFalse(RoundSummary.reachedGoal(before: 0, after: 1, goal: 0))
    }

    // MARK: StemLayout

    func testFillInBlankStemIsNotSplit() {
        let stem = "星港郵局會分揀：①顏色的郵票，中央為 ②區，對於寄往外環的包裹，會 ③轉運。以上①、②、③分別填入何者，全為正確？"
        XCTAssertFalse(StemLayout.isStatementList(stem))
        XCTAssertEqual(StemLayout.display(stem), stem)
    }

    func testAdjacentMarkersAreBackReferences() {
        let stem = "上方可調節①光與②光的配比，下方提供③光。以上①②③各為何？"
        XCTAssertEqual(StemLayout.display(stem), stem)
    }

    func testRestartedSequenceIsNotSplit() {
        let stem = "甲組：①近視 ②遠視。乙組：①散光 ②老花。下列何者正確？"
        XCTAssertEqual(StemLayout.display(stem), stem)
    }

    func testStatementListStillSplits() {
        let stem = "下列敘述何者正確？①角膜無血管 ②水晶體有血管 ③玻璃體為膠狀"
        XCTAssertTrue(StemLayout.isStatementList(stem))
        XCTAssertEqual(StemLayout.display(stem), "下列敘述何者正確？\n①角膜無血管\n②水晶體有血管\n③玻璃體為膠狀")
    }

    func testSingleMarkerOrOtherStartIsNotSplit() {
        XCTAssertEqual(StemLayout.display("只有①一個"), "只有①一個")
        XCTAssertEqual(StemLayout.display("②先出現 ③再出現"), "②先出現 ③再出現")
    }
}
