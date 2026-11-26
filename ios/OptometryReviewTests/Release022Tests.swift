import XCTest
@testable import OptometryReview

/// 0.2.2: 讀書夥伴 replaces the leaderboard (no rank, no others' accuracy).
final class Release022Tests: XCTestCase {
    private func entry(_ id: String, _ name: String, me: Bool = false, rank: Int = 1, accuracy: Double? = 0.7) -> LeaderboardEntry {
        LeaderboardEntry(id: id, name: name, rank: rank, correct: 10, days: 2, accuracy: accuracy, me: me)
    }

    func testCardsListMeFirstThenOthersByNameIgnoringRank() {
        let board = LeaderboardBoard(joined: true, week: nil, entries: [
            entry("c", "阿凱", rank: 1), entry("b", "Amy", rank: 2), entry("a", "小禾", me: true, rank: 3), entry("d", "Amy", rank: 4),
        ])
        XCTAssertEqual(board.ordered.map(\.id), ["a", "b", "d", "c"])
    }

    func testWeekOverWeekText() {
        XCTAssertEqual(LeaderboardText.weekOverWeek(this: 74, last: 62), "比上週多 12 題")
        XCTAssertEqual(LeaderboardText.weekOverWeek(this: 50, last: 62), "比上週少 12 題")
        XCTAssertEqual(LeaderboardText.weekOverWeek(this: 62, last: 62), "和上週一樣")
        XCTAssertEqual(LeaderboardText.weekOverWeek(this: 0, last: 0), "和上週一樣")
        XCTAssertNil(LeaderboardText.weekOverWeek(this: 74, last: nil))
    }

    func testOthersAccuracyIsNeverRendered() {
        XCTAssertEqual(LeaderboardText.ownAccuracyLine(entry("a", "我", me: true, accuracy: 0.68)), "正確率 68%")
        XCTAssertNil(LeaderboardText.ownAccuracyLine(entry("a", "我", me: true, accuracy: nil)))
        // An older or misbehaving server that still sends another person's accuracy must not leak it into the UI.
        XCTAssertNil(LeaderboardText.ownAccuracyLine(entry("b", "Amy", me: false, accuracy: 0.95)))
    }

    func testBoardDecodesMeLastWeekAndToleratesOldServer() throws {
        let base = #""joined": true, "week": {"start": "2026-10-05", "end": "2026-10-11"}, "entries": []"#
        let withMe = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(("{" + base + #", "me": {"lastWeekCorrect": 62}}"#).utf8))
        XCTAssertEqual(withMe.lastWeekCorrect, 62)
        let nullLast = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(("{" + base + #", "me": {"lastWeekCorrect": null}}"#).utf8))
        XCTAssertNil(nullLast.lastWeekCorrect)
        let old = try JSONDecoder().decode(LeaderboardBoard.self, from: Data(("{" + base + "}").utf8))
        XCTAssertNil(old.lastWeekCorrect)
    }
}
