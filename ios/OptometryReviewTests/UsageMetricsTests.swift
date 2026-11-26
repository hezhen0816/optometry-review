import XCTest
@testable import OptometryReview

final class UsageMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testForegroundClockExcludesBackgroundAndInactiveIntervals() {
        var clock = UsageForegroundClock()
        clock.resume(at: start)
        clock.resume(at: start.addingTimeInterval(5))
        clock.pause(at: start.addingTimeInterval(10))
        clock.pause(at: start.addingTimeInterval(100))
        clock.resume(at: start.addingTimeInterval(1800))
        XCTAssertEqual(clock.take(at: start.addingTimeInterval(1807)), 17)
        XCTAssertEqual(clock.take(at: start.addingTimeInterval(3600)), 0)
    }

    func testClockClampsBackwardWallClockAndStartsFreshAfterTake() {
        var clock = UsageForegroundClock()
        clock.resume(at: start)
        XCTAssertEqual(clock.take(at: start.addingTimeInterval(-10)), 0)
        clock.resume(at: start)
        XCTAssertEqual(clock.take(at: start.addingTimeInterval(3)), 3)
    }

    func testStateGateSuppressesRepeatsButAllowsChangesAndNewForeground() {
        var gate = UsageStateGate<String>()
        XCTAssertTrue(gate.accepts("day1:due20"))
        XCTAssertFalse(gate.accepts("day1:due20"))
        XCTAssertTrue(gate.accepts("day1:due19"))
        XCTAssertFalse(gate.accepts("day1:due19"))
        XCTAssertTrue(gate.accepts("day2:due19"))
        gate.reset()
        XCTAssertTrue(gate.accepts("day2:due19"))
    }

    @MainActor
    func testTodayStatusUsesSummaryAndExistingQuotaWithoutChangingThePlan() {
        let defaults = UserDefaults(suiteName: "opto.usage.metrics.\(UUID())")!
        defaults.set(20, forKey: SettingsKey.dailyGoal)
        let summary = TodaySummary(answeredToday: 8, plan: .init(dueIDs: ["due", "retry"], newIDs: ["new"]),
                                   reviewBySubject: [:], totalAttempts: 8, correctToday: 6, retryIDs: ["retry"])
        let status = TodayUsageStatus(summary: summary, defaults: defaults, now: start)
        XCTAssertEqual(status.dueCount, 1)
        XCTAssertEqual(status.retryCount, 1)
        XCTAssertEqual(status.newQuota, 5)
        XCTAssertEqual(status.correctToday, 6)
        XCTAssertTrue(status.fields["examDaysLeft"] is NSNull)
        XCTAssertFalse(status.reviewOnly)
        XCTAssertEqual(summary.plan.newIDs, ["new"])
        var gate = UsageStateGate<TodayUsageStatus>()
        XCTAssertTrue(gate.accepts(status))
        XCTAssertFalse(gate.accepts(TodayUsageStatus(summary: summary, defaults: defaults, now: start.addingTimeInterval(60))))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        XCTAssertTrue(gate.accepts(TodayUsageStatus(summary: summary, defaults: defaults, now: tomorrow)))
        defaults.set(NewRatioMode.reviewOnly.rawValue, forKey: SettingsKey.newRatioMode)
        defaults.set(tomorrow.timeIntervalSince1970, forKey: SettingsKey.examDate)
        let reviewOnly = TodayUsageStatus(summary: summary, defaults: defaults, now: start)
        XCTAssertTrue(reviewOnly.reviewOnly)
        XCTAssertEqual(reviewOnly.newQuota, 0)
        XCTAssertEqual(reviewOnly.examDaysLeft, 1)
    }

    func testReadingMetricsKeepMaxDepthAndOnlyOperationFlags() {
        var reading = AIReadingUsage(qid: "q1", trigger: "auto", cached: true)
        reading.clock.resume(at: start)
        reading.clock.pause(at: start.addingTimeInterval(4))
        reading.clock.resume(at: start.addingTimeInterval(100))
        reading.saw(depth: -1)
        reading.saw(depth: 0.6)
        reading.saw(depth: 0.2)
        reading.saw(depth: .nan)
        XCTAssertEqual(reading.maxScrollDepth, 0.6)
        reading.saw(depth: 2)
        reading.otherOptions = true
        reading.followupAsked = true
        let fields = reading.finish(at: start.addingTimeInterval(103))
        XCTAssertEqual(fields["seconds"] as? Double, 7)
        XCTAssertEqual(fields["maxScrollDepth"] as? Double, 1)
        XCTAssertEqual(fields["otherOptions"] as? Bool, true)
        XCTAssertEqual(fields["followupAsked"] as? Bool, true)
        XCTAssertEqual(Set(fields.keys), ["action", "qid", "trigger", "cached", "seconds", "maxScrollDepth",
                                          "otherOptions", "handout", "regenerated", "followupAsked"])
        let next = AIReadingUsage(qid: "q2", trigger: "manual", cached: false)
        XCTAssertEqual(next.maxScrollDepth, 0)
        XCTAssertFalse(next.otherOptions)
    }

    @MainActor
    func testReplacingPanelKeepsOneOpenAndReadingFlagsUntilExplicitClose() {
        var events: [[String: Any]] = []
        var now = start
        let session = AIUsageSession(now: { now }, sink: { _, fields in events.append(fields) })
        let narrow = UUID(), wide = UUID()
        session.attach(narrow, qid: "q1", trigger: "auto", cached: true)
        session.update(narrow, visible: true, depth: 0.4)
        session.value?.otherOptions = true
        now = start.addingTimeInterval(5)
        session.attach(wide, qid: "q1", trigger: "manual", cached: false)
        session.detach(narrow)
        session.update(wide, visible: true, depth: 0.8)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(session.value?.trigger, "auto")
        XCTAssertEqual(session.value?.cached, true)
        XCTAssertEqual(session.value?.otherOptions, true)
        now = start.addingTimeInterval(8)
        session.finish()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1]["seconds"] as? Double, 8)
        XCTAssertEqual(events[1]["maxScrollDepth"] as? Double, 0.8)
        session.finish()
        XCTAssertEqual(events.count, 2)
        session.attach(wide, qid: "q1", trigger: "manual", cached: true)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(session.value?.otherOptions, false)
        XCTAssertEqual(events[2]["trigger"] as? String, "manual")
        session.finish()
        session.attach(wide, qid: "q1", trigger: "auto", cached: true)
        XCTAssertEqual(events[4]["trigger"] as? String, "auto")
    }


    @MainActor
    func testPanelReplacementGapKeepsTheOpenButExcludesDetachedTime() {
        var events: [[String: Any]] = []
        var now = start
        let session = AIUsageSession(now: { now }, sink: { _, fields in events.append(fields) })
        let first = UUID(), replacement = UUID()
        session.attach(first, qid: "q1", trigger: "auto", cached: true)
        session.update(first, visible: true)
        now = start.addingTimeInterval(3)
        session.detach(first)
        now = start.addingTimeInterval(100)
        session.attach(replacement, qid: "q1", trigger: "manual", cached: false)
        XCTAssertEqual(events.count, 1)
        session.update(replacement, visible: true)
        now = start.addingTimeInterval(102)
        session.finish()
        XCTAssertEqual(events[1]["seconds"] as? Double, 5)
        XCTAssertEqual(events[1]["trigger"] as? String, "auto")
        XCTAssertEqual(events[1]["cached"] as? Bool, true)
    }

}
