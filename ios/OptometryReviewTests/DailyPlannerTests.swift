import XCTest
@testable import OptometryReview

final class DailyPlannerTests: XCTestCase {
    private let subjects = ["S1", "S2", "S3"]

    private func pool(_ n: Int) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: subjects.map { s in (s, (1...n).map { "\(s)-\($0)" }) })
    }

    func testDueFirstOldestFirstThenNewToGoal() {
        let d0 = Date(timeIntervalSince1970: 0)
        let due: [DailyPlanner.DueItem] = [
            .init(id: "late", due: d0.addingTimeInterval(86_400 * 2), subject: "S1"),
            .init(id: "old", due: d0, subject: "S1"),
            .init(id: "mid", due: d0.addingTimeInterval(86_400), subject: "S1"),
        ]
        let plan = DailyPlanner.plan(due: due, unseenBySubject: pool(5), accuracy: [:], goal: 6,
                                     answeredToday: 0, subjectOrder: subjects)
        XCTAssertEqual(plan.dueIDs, ["old", "mid", "late"])
        XCTAssertEqual(plan.newIDs.count, 3)
        XCTAssertEqual(plan.queue.prefix(3), ["old", "mid", "late"])
    }

    func testNewFloorIsInsideGoalDespiteBacklog() {
        let due = (0..<8).map { DailyPlanner.DueItem(id: "d\($0)", due: Date(timeIntervalSince1970: Double($0)), subject: "S1") }
        let plan = DailyPlanner.plan(due: due, unseenBySubject: pool(5), accuracy: [:], goal: 5,
                                     answeredToday: 0, subjectOrder: subjects)
        XCTAssertEqual(plan.dueIDs.count, 8)
        XCTAssertEqual(plan.newIDs.count, 1)
        XCTAssertTrue(Set(plan.newIDs).isSubset(of: Set(plan.queue.prefix(5))))
        XCTAssertEqual(plan.queue.suffix(4), ["d4", "d5", "d6", "d7"])
    }

    func testTwentyQuestionGoalReservesFiveNewAndCountsFirstAttempts() {
        let due = (0..<30).map { DailyPlanner.DueItem(id: "d\($0)", due: Date(timeIntervalSince1970: Double($0)), subject: "S1") }
        let plan = DailyPlanner.plan(due: due, unseenBySubject: pool(20), accuracy: [:], goal: 20,
                                     answeredToday: 10, newAnsweredToday: 2, subjectOrder: subjects)
        XCTAssertEqual(plan.newIDs.count, 3)
        XCTAssertEqual(Array(plan.queue.prefix(7)), Array(plan.dueIDs.prefix(7)))
        XCTAssertTrue(Set(plan.newIDs).isSubset(of: Set(plan.queue.prefix(10))))
        let filled = DailyPlanner.plan(due: due, unseenBySubject: pool(20), accuracy: [:], goal: 20,
                                       answeredToday: 20, newAnsweredToday: 5, subjectOrder: subjects)
        XCTAssertTrue(filled.newIDs.isEmpty)
        let limited = DailyPlanner.plan(due: due, unseenBySubject: ["S1": ["one"]], accuracy: [:], goal: 20,
                                        answeredToday: 0, subjectOrder: subjects)
        XCTAssertEqual(limited.newIDs, ["one"])
    }

    func testAnsweredTodayReducesNewFill() {
        let plan = DailyPlanner.plan(due: [], unseenBySubject: pool(10), accuracy: [:], goal: 20,
                                     answeredToday: 15, subjectOrder: subjects)
        XCTAssertEqual(plan.newIDs.count, 5)
    }

    func testDueRoundRobinPreservesSubjectOrderAndOldestThenIDWithinSubject() {
        let d = Date(timeIntervalSince1970: 0)
        let due: [DailyPlanner.DueItem] = [
            .init(id: "s1-late", due: d.addingTimeInterval(1), subject: subjects[0]),
            .init(id: "s3-only", due: d, subject: subjects[2]),
            .init(id: "s2-b", due: d, subject: subjects[1]),
            .init(id: "s1-old", due: d, subject: subjects[0]),
            .init(id: "s2-a", due: d, subject: subjects[1]),
            .init(id: "s1-last", due: d.addingTimeInterval(2), subject: subjects[0]),
        ]
        let plan = DailyPlanner.plan(due: due, unseenBySubject: pool(5), accuracy: [:], goal: 4,
                                     answeredToday: 0, subjectOrder: subjects)
        XCTAssertEqual(plan.dueIDs, ["s1-old", "s2-a", "s3-only", "s1-late", "s2-b", "s1-last"])
        XCTAssertEqual(Array(plan.queue.prefix(4)), ["s1-old", "s2-a", "s3-only", "S1-1"])
        XCTAssertEqual(Set(plan.dueIDs), Set(due.map(\.id)))
        let reversed = DailyPlanner.plan(due: Array(due.reversed()), unseenBySubject: pool(5), accuracy: [:], goal: 4,
                                         answeredToday: 0, subjectOrder: subjects)
        XCTAssertEqual(plan, reversed)
    }

    func testRoundRobinWithoutHistory() {
        let ids = DailyPlanner.pickNew(count: 6, unseenBySubject: pool(5), accuracy: [:], subjectOrder: subjects)
        XCTAssertEqual(ids, ["S1-1", "S2-1", "S3-1", "S1-2", "S2-2", "S3-2"])
    }

    func testWeightsTowardLowestAccuracy() {
        let acc: [String: DailyPlanner.SubjectAccuracy] = [
            "S1": .init(correct: 9, total: 10),  // weight 0.1
            "S2": .init(correct: 2, total: 10),  // weight 0.8
            "S3": .init(correct: 5, total: 10),  // weight 0.5
        ]
        let ids = DailyPlanner.pickNew(count: 10, unseenBySubject: pool(20), accuracy: acc, subjectOrder: subjects)
        let counts = Dictionary(grouping: ids, by: { String($0.prefix(2)) }).mapValues(\.count)
        XCTAssertEqual(ids.first, "S2-1")
        XCTAssertGreaterThan(counts["S2", default: 0], counts["S3", default: 0])
        XCTAssertGreaterThan(counts["S3", default: 0], counts["S1", default: 0])
    }

    func testExhaustedSubjectIsSkipped() {
        var p = pool(1)
        p["S2"] = []
        let ids = DailyPlanner.pickNew(count: 5, unseenBySubject: p, accuracy: [:], subjectOrder: subjects)
        XCTAssertEqual(ids, ["S1-1", "S3-1"])
    }

    func testSeededShuffleIsStable() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42)
        XCTAssertEqual(Array(0..<50).shuffled(using: &a), Array(0..<50).shuffled(using: &b))
    }
}
