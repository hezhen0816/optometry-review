import XCTest
@testable import OptometryReview

/// 0.3.0: 「現在分析」 button states mirror the server's GET /insights/run.
final class ManualAnalysisTests: XCTestCase {

    private func status(_ json: String) -> ManualAnalysisStatus? { ManualAnalysisStatus.decode(Data(json.utf8)) }

    func testDecodesStatus() {
        XCTAssertEqual(status(#"{"allowed":true,"reason":null,"newAnswers":12,"needed":10,"lastAt":null}"#),
                       ManualAnalysisStatus(allowed: true, reason: nil, newAnswers: 12, needed: 10))
        XCTAssertEqual(status(#"{"allowed":false,"reason":"not_enough_answers","newAnswers":4,"needed":10}"#)?.reason,
                       "not_enough_answers")
        XCTAssertNil(status(#"{"reason":"x"}"#))
        XCTAssertNil(status("not json"))
    }

    func testRequestBodyCarriesTheCardPoints() throws {
        let body = WeakAnalysisClient.manualBody(points: ["U-1#2", "U-3#1", "U-4#7"])
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"points":["U-1#2","U-3#1","U-4#7"]}"#)
        let capped = try XCTUnwrap(JSONSerialization.jsonObject(with: WeakAnalysisClient.manualBody(points: ["a", "b", "c", "d"])) as? [String: [String]])
        XCTAssertEqual(capped["points"], ["a", "b", "c"])
    }

    func testRefusalBody() {
        let body = Data(#"{"error":"not_enough_answers","newAnswers":7,"needed":10}"#.utf8)
        XCTAssertEqual(ManualAnalysisStatus.decodeRefusal(body),
                       ManualAnalysisStatus(allowed: false, reason: "not_enough_answers", newAnswers: 7, needed: 10))
        XCTAssertNil(ManualAnalysisStatus.decodeRefusal(Data(#"{"error":"busy"}"#.utf8)))
    }

    func testButtonLabels() {
        let label = ManualAnalysisStatus.label
        XCTAssertNil(label(nil, false))
        XCTAssertEqual(label(ManualAnalysisStatus(allowed: true, reason: nil, newAnswers: 10, needed: 10), false)?.title, "現在分析")
        XCTAssertEqual(label(ManualAnalysisStatus(allowed: true, reason: nil, newAnswers: 10, needed: 10), false)?.enabled, true)
        let today = label(ManualAnalysisStatus(allowed: false, reason: "already_today", newAnswers: 30, needed: 10), false)
        XCTAssertEqual(today?.title, "今天已分析過")
        XCTAssertEqual(today?.enabled, false)
        XCTAssertEqual(label(ManualAnalysisStatus(allowed: false, reason: "not_enough_answers", newAnswers: 4, needed: 10), false)?.title,
                       "再答 6 題可分析")
        let running = label(ManualAnalysisStatus(allowed: true, reason: nil, newAnswers: 10, needed: 10), true)
        XCTAssertEqual(running?.title, "分析中")
        XCTAssertEqual(running?.enabled, false)
    }

    @MainActor func testOfflineFailureTextIsAboutAnalysis() {
        XCTAssertEqual(ManualAnalysisStore.failureText(.offline), "分析需要網路，連上網路後再試")
    }
}
