import XCTest
@testable import OptometryReview

/// 0.2 UX review fixes: 成績 verdict, unit-page average line, 今日 backlog note, tab re-tap, back titles.
final class UXReviewFixesTests: XCTestCase {

    func testVerdictHeadline() {
        XCTAssertEqual(PassProjection.Result.pass(average: 72).headline, "推估及格")
        XCTAssertEqual(PassProjection.Result.fail(average: 63.6, zeroSubjects: ["低視力學"]).headline, "未達：低視力學 0 分")
        XCTAssertEqual(PassProjection.Result.fail(average: 59.6, zeroSubjects: []).headline, "未達：平均低於 60")
        XCTAssertEqual(PassProjection.Result.missing(["視光學", "低視力學"]).headline, "還不能推估：缺 2 科")
    }

    func testUnitAverageDetailLeavesTheMinimumToTheChip() {
        let floor = UnitHistory.Stat(counts: [4, 6, 9])
        XCTAssertTrue(floor.showsFloor)
        XCTAssertEqual(floor.averageDetail, "題 ・ 最多 9")
        let noFloor = UnitHistory.Stat(counts: [0, 2, 5])
        XCTAssertFalse(noFloor.showsFloor)
        XCTAssertEqual(noFloor.averageDetail, "題 ・ 最少 0、最多 5")
    }

    func testTappingTheActiveTabPopsItToItsRoot() {
        let router = AppRouter()
        router.tab = AppRouter.Tab.stats
        router.select(AppRouter.Tab.stats)
        XCTAssertEqual(router.rootRequest(AppRouter.Tab.stats), 1)
        router.select(AppRouter.Tab.today)
        XCTAssertEqual(router.rootRequest(AppRouter.Tab.today), 0, "switching tabs keeps the other stack")
        XCTAssertEqual(router.tab, AppRouter.Tab.today)
        let units = router.rootRequest(AppRouter.Tab.units)
        router.tab = AppRouter.Tab.units
        router.select(AppRouter.Tab.units)
        XCTAssertEqual(router.rootRequest(AppRouter.Tab.units), units + 1)
    }

    func testBackButtonShowsTheParentName() {
        XCTAssertEqual(BackButton.title("返回錯題本"), "錯題本")
        XCTAssertEqual(BackButton.title("返回"), "返回")
    }

    func testTrendLabelSitsAwayFromTheLastSegment() {
        let d = Date(timeIntervalSince1970: 0)
        func pts(_ v: [Double]) -> [ScoreHistory.Point] {
            v.enumerated().map { ScoreHistory.Point(date: d.addingTimeInterval(Double($0.offset)), average: $0.element, subjectCount: 5) }
        }
        XCTAssertTrue(StatsView.lastLabelBelow(pts([70, 63.6])))
        XCTAssertFalse(StatsView.lastLabelBelow(pts([55, 63.6])))
        XCTAssertFalse(StatsView.lastLabelBelow(pts([63.6])))
    }
}
