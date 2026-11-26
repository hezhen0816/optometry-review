import XCTest
@testable import OptometryReview

final class UpdateNoticeTests: XCTestCase {
    private func eval(build: Int? = 100, latest: Int? = nil, min: Int? = nil, message: String? = nil, dismissed: Int? = nil) -> UpdateNotice? {
        UpdateNotice.evaluate(build: build, latest: latest, min: min, message: message, dismissedLatest: dismissed)
    }

    func testNothingWhenUpToDateOrNull() {
        XCTAssertNil(eval(latest: nil, min: nil))
        XCTAssertNil(eval(latest: 100, min: 100))
        XCTAssertNil(eval(latest: 99, min: 50))
        XCTAssertNil(eval(build: nil, latest: 200, min: 200))
    }

    func testAvailableAndDismissal() {
        let n = eval(latest: 101)
        XCTAssertEqual(n?.kind, .available)
        XCTAssertEqual(n?.text, UpdateNotice.defaultAvailableText)
        XCTAssertNil(eval(latest: 101, dismissed: 101))
        XCTAssertEqual(eval(latest: 102, dismissed: 101)?.kind, .available)
    }

    func testRequiredIgnoresDismissalAndUsesMessage() {
        let n = eval(latest: 101, min: 101, message: " 請更新 ", dismissed: 101)
        XCTAssertEqual(n?.kind, .required)
        XCTAssertEqual(n?.text, "請更新")
        XCTAssertEqual(eval(latest: nil, min: 150)?.kind, .required)
        XCTAssertEqual(eval(min: 150, message: "  ")?.text, UpdateNotice.defaultRequiredText)
    }

    func testDecodeAcceptsStringsNumbersAndNull() {
        let a = LatestBuildInfo.decode(Data(#"{"latestBuild":"202610091907","minBuild":null,"message":null}"#.utf8))
        XCTAssertEqual(a, LatestBuildInfo(latest: 202610091907, min: nil, message: nil))
        let b = LatestBuildInfo.decode(Data(#"{"latestBuild":5,"minBuild":"abc","message":"hi"}"#.utf8))
        XCTAssertEqual(b, LatestBuildInfo(latest: 5, min: nil, message: "hi"))
        XCTAssertNil(LatestBuildInfo.decode(Data("nope".utf8)))
    }
}
