import XCTest
import SwiftData
@testable import OptometryReview

/// 0.3.3 今日: neglected-subject sampling, 五科進度 and the 練這科 queue.
final class TodayRedesignTests: XCTestCase {
    private let subjects = ["S1", "S2", "S3", "S4", "S5"]

    private func pool(_ n: Int) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: subjects.map { s in (s, (1...n).map { "\(s)-\($0)" }) })
    }

    private func counts(_ ids: [String]) -> [String: Int] {
        Dictionary(grouping: ids, by: { String($0.prefix(2)) }).mapValues(\.count)
    }

    // MARK: Sampling

    func testNeglectBoostFallsFromTwoToOneAtTheThreshold() {
        XCTAssertEqual(DailyPlanner.neglectBoost(answered: 0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(DailyPlanner.neglectBoost(answered: 20), 1.5, accuracy: 1e-9)
        XCTAssertEqual(DailyPlanner.neglectBoost(answered: 40), 1.0)
        XCTAssertEqual(DailyPlanner.neglectBoost(answered: 300), 1.0)
        XCTAssertEqual(DailyPlanner.neglectBoost(answered: nil), 1.0)
    }

    func testNeglectedSubjectsGetTheLargerShare() {
        // Same shape as the real data: three barely practised subjects, two well practised.
        let answered = ["S1": 10, "S2": 9, "S3": 82, "S4": 118, "S5": 8]
        let ids = DailyPlanner.pickNew(count: 12, unseenBySubject: pool(50), accuracy: [:], subjectOrder: subjects,
                                       answeredBySubject: answered)
        let c = counts(ids)
        let neglected = ["S1", "S2", "S5"].map { c[$0, default: 0] }.reduce(0, +)
        let practised = ["S3", "S4"].map { c[$0, default: 0] }.reduce(0, +)
        XCTAssertEqual(ids.count, 12)
        XCTAssertGreaterThan(neglected, 7, "plain round-robin would give 7.2 of 12")
        XCTAssertLessThan(practised, 5)
        XCTAssertGreaterThanOrEqual(c["S3", default: 0], 1, "practised subjects are thinned, not dropped")
        XCTAssertGreaterThanOrEqual(c["S4", default: 0], 1)
    }

    func testWithoutAnsweredCountsNothingChanges() {
        let a = DailyPlanner.pickNew(count: 11, unseenBySubject: pool(5), accuracy: [:], subjectOrder: subjects)
        let b = DailyPlanner.pickNew(count: 11, unseenBySubject: pool(5), accuracy: [:], subjectOrder: subjects,
                                     answeredBySubject: [:])
        XCTAssertEqual(a, b)
        // Everything past the threshold is the same as no information.
        let c = DailyPlanner.pickNew(count: 11, unseenBySubject: pool(5), accuracy: [:], subjectOrder: subjects,
                                     answeredBySubject: Dictionary(uniqueKeysWithValues: subjects.map { ($0, 100) }))
        XCTAssertEqual(a, c)
    }

    func testNeglectKeepsWeakSubjectLogic() {
        // Equally neglected: the low-accuracy subject still leads.
        let acc: [String: DailyPlanner.SubjectAccuracy] = ["S1": .init(correct: 9, total: 10),
                                                           "S2": .init(correct: 2, total: 10)]
        let answered = Dictionary(uniqueKeysWithValues: subjects.map { ($0, 5) })
        let ids = DailyPlanner.pickNew(count: 10, unseenBySubject: pool(20), accuracy: acc, subjectOrder: subjects,
                                       answeredBySubject: answered)
        XCTAssertGreaterThan(counts(ids)["S2", default: 0], counts(ids)["S1", default: 0])
        // A weak but well practised subject can still be outweighed by a neglected, accurate one.
        let mixed = DailyPlanner.pickNew(count: 6, unseenBySubject: pool(20), accuracy: ["S1": .init(correct: 2, total: 10)],
                                         subjectOrder: ["S1", "S2"], answeredBySubject: ["S1": 200, "S2": 0])
        XCTAssertGreaterThan(counts(mixed)["S2", default: 0], counts(mixed)["S1", default: 0])
    }

    func testExhaustedNeglectedSubjectDoesNotStallThePick() {
        var p = pool(10)
        p["S1"] = []
        let ids = DailyPlanner.pickNew(count: 8, unseenBySubject: p, accuracy: [:], subjectOrder: subjects,
                                       answeredBySubject: ["S1": 0, "S2": 50])
        XCTAssertEqual(ids.count, 8)
        XCTAssertNil(counts(ids)["S1"])
    }

    func testPlanPassesAnsweredCountsToNewPicks() {
        let answered = ["S1": 0, "S2": 100, "S3": 100, "S4": 100, "S5": 100]
        let plan = DailyPlanner.plan(due: [], unseenBySubject: pool(30), accuracy: [:], goal: 10, answeredToday: 0,
                                     subjectOrder: subjects, ratioMode: .custom, customNewPercent: 100,
                                     answeredBySubject: answered)
        XCTAssertEqual(plan.newIDs.count, 10)
        XCTAssertGreaterThan(counts(plan.newIDs)["S1", default: 0], 2, "round-robin would give 2")
    }

    // MARK: 五科進度

    private func question(_ id: String, subject: String, year: Int = 115) -> Question {
        Question(id: id, code: "\(year)100", year: year, examKind: "一般", subject: subject, number: 1, stem: "t",
                 options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A",
                 corrected: false, correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false)
    }

    func testProgressFollowsScopeAndFixedSubjectOrder() {
        let s = Subjects.all
        var qs: [Question] = []
        for (i, subject) in s.enumerated() {
            qs += (0..<(i + 3)).map { question("114-\(i)-\($0)", subject: subject, year: 114) }
            qs += (0..<5).map { question("115-\(i)-\($0)", subject: subject, year: 115) }
        }
        var scope = PracticeScope.all
        let all = SubjectProgress.compute(pool: scope.filter(qs), answeredIDs: ["114-0-0", "115-0-1", "115-4-0", "ai:x"])
        XCTAssertEqual(all.map(\.subject), s)
        XCTAssertEqual(all.map(\.total), [8, 9, 10, 11, 12])
        XCTAssertEqual(all.map(\.answered), [2, 0, 0, 0, 1])
        scope.years = YearSelection(mode: .single, from: 115, to: 115)
        let y = SubjectProgress.compute(pool: scope.filter(qs), answeredIDs: ["114-0-0", "115-0-1", "115-4-0"])
        XCTAssertEqual(y.map(\.total), [5, 5, 5, 5, 5], "the denominator follows the 練習範圍")
        XCTAssertEqual(y.map(\.answered), [1, 0, 0, 0, 1], "answers outside the scope are not counted")
    }

    func testAIQuestionsNeverCountAndNeglectNeedsFewerThanForty() {
        let aiQ = question("ai:1", subject: Subjects.all[0])
        let p = SubjectProgress.compute(pool: [aiQ], answeredIDs: [aiQ.id])
        XCTAssertEqual(p[0].total, 0)
        XCTAssertEqual(p[0].answered, 0)
        XCTAssertEqual(SubjectProgress(subject: "S", answered: 39, total: 800).isNeglected, true)
        XCTAssertEqual(SubjectProgress(subject: "S", answered: 40, total: 800).isNeglected, false)
        // A scope smaller than 40 is only 「很少練」 until it is all done.
        XCTAssertEqual(SubjectProgress(subject: "S", answered: 10, total: 50).isNeglected, true)
        XCTAssertEqual(SubjectProgress(subject: "S", answered: 20, total: 20).isNeglected, false)
        XCTAssertEqual(SubjectProgress(subject: "S", answered: 40, total: 800).fraction, 0.05, accuracy: 1e-9)
    }

    func testNeglectIsFlaggedOnlyWhenPracticeIsLopsided() {
        func p(_ answered: Int, total: Int = 800) -> SubjectProgress { SubjectProgress(subject: "S", answered: answered, total: total) }
        XCTAssertFalse(SubjectProgress.flagsNeglect([p(0), p(0), p(0), p(0), p(0)]), "a fresh user sees neutral rows")
        XCTAssertFalse(SubjectProgress.flagsNeglect([p(10), p(39), p(5), p(0), p(20)]), "nobody reached 40 yet")
        XCTAssertTrue(SubjectProgress.flagsNeglect([p(40), p(0), p(0), p(0), p(0)]), "one subject at 40 makes the rest stand out")
        XCTAssertFalse(SubjectProgress.flagsNeglect([p(40), p(80), p(41), p(300), p(40)]), "all practised: nothing to flag")
        XCTAssertFalse(SubjectProgress.flagsNeglect([p(0, total: 0), p(0)]), "an empty scope is not a reached subject")
        XCTAssertTrue(SubjectProgress.flagsNeglect([p(20, total: 20), p(3)]), "a small scope finished counts as reached")
    }

    func testDailyGoalIsClampedIntoItsRange() {
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(nil), 20)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal("x"), 20)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(4), 5)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(0), 5)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(-3), 5)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(30), 30)
        XCTAssertEqual(SettingsKey.sanitizedDailyGoal(9999), 100)
        let d = UserDefaults(suiteName: "dailyGoalRepair-\(UUID().uuidString)")!
        SettingsKey.repairDailyGoal(defaults: d)
        XCTAssertNil(d.object(forKey: SettingsKey.dailyGoal), "an unset goal stays unset (the views use the default)")
        d.set(4, forKey: SettingsKey.dailyGoal)
        SettingsKey.repairDailyGoal(defaults: d)
        XCTAssertEqual(d.integer(forKey: SettingsKey.dailyGoal), 5)
        d.set(250, forKey: SettingsKey.dailyGoal)
        SettingsKey.repairDailyGoal(defaults: d)
        XCTAssertEqual(d.integer(forKey: SettingsKey.dailyGoal), 100)
    }

    // MARK: 練這科

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    private func day(_ offset: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: offset,
                      to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour))!)!
    }

    @MainActor
    func testSubjectQueueTakesItsDueReviewsFirstThenNewOfTheScopeOnly() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "today-redesign-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope = PracticeScope.all
        scope.years = YearSelection(mode: .single, from: 115, to: 115)
        ScopeStore.setDaily(scope, defaults: defaults)
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar),
                               defaults: defaults, usageSink: { _, _ in })
        let a = Subjects.all[1], b = Subjects.all[2]
        let mistakes = (0..<3).map { question("114-m\($0)", subject: a, year: 114) }
        let otherMistake = question("114-o", subject: b, year: 114)
        for q in mistakes + [otherMistake] {
            store.commit(question: q, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-5))
        }
        let fresh = (0..<20).map { question("115-a\($0)", subject: a) } + (0..<20).map { question("115-b\($0)", subject: b) }
            + (0..<5).map { question("114-new\($0)", subject: a, year: 114) }
        let bank = QuestionBank(questions: mistakes + [otherMistake] + fresh)
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0))
        let (queue, retries) = store.subjectQueue(subject: a, summary: summary, bank: bank, includeSpecial: false, now: day(0))
        XCTAssertEqual(queue.count, StudyStore.subjectSessionSize)
        XCTAssertEqual(Set(queue.prefix(3)), Set(mistakes.map(\.id)), "due reviews come first")
        let rest = queue.dropFirst(3)
        XCTAssertEqual(rest.count, 7)
        XCTAssertTrue(rest.allSatisfy { $0.hasPrefix("115-a") }, "new questions: same subject, inside the 練習範圍")
        XCTAssertTrue(retries.isSubset(of: Set(queue)))
        // A subject with nothing due and nothing new in the scope gets an empty queue (the view falls back to 自選練習).
        let none = store.subjectQueue(subject: Subjects.all[4], summary: summary, bank: bank, includeSpecial: false, now: day(0))
        XCTAssertTrue(none.queue.isEmpty)
        // Progress in the summary counts the answered question of the scope only.
        XCTAssertEqual(summary.subjectProgress.map(\.subject), Subjects.all)
        XCTAssertEqual(summary.subjectProgress[1].total, 20)
        XCTAssertEqual(summary.subjectProgress[1].answered, 0)
    }

    @MainActor
    func testSubjectSessionAnswersCountTowardTheDailyGoal() throws {
        // The session is a daily session: answers are stored as attempts outside the mock-exam source, which is
        // what the goal count (distinct correct answers of the day) adds up.
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), usageSink: { _, _ in })
        let q = question("115-x", subject: Subjects.all[1])
        store.commit(question: q, chosen: "A", correct: true, unsure: false, reason: nil, now: day(0))
        let bank = QuestionBank(questions: [q])
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0, hour: 10)).correctToday, 1)
        let request = SessionRequest(queue: [q.id], doneBefore: 1, isDaily: true)
        XCTAssertTrue(request.isDaily)
        XCTAssertTrue(request.retriesWrong)
    }

    @MainActor
    func testSubjectQueueKeepsConfirmationsWithinTheDailyCapAndItsAnswersCountTowardTheGoal() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "today-redesign-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar),
                               defaults: defaults, usageSink: { _, _ in })
        let a = Subjects.all[1]
        // Twelve 確認題 of one subject, each first answered correctly on its own day, all overdue today.
        let confirmations = (0..<12).map { question("115-c\($0)", subject: a) }
        for (i, q) in confirmations.enumerated() {
            store.commit(question: q, chosen: "A", correct: true, unsure: false, reason: nil, now: day(-30 + i))
        }
        let mistake = question("114-m", subject: a, year: 114)
        store.commit(question: mistake, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-5))
        let bank = QuestionBank(questions: confirmations + [mistake])
        XCTAssertTrue(confirmations.allSatisfy { store.record(for: $0.id)?.schedule.isConfirmation == true })

        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0))
        let (queue, _) = store.subjectQueue(subject: a, summary: summary, bank: bank, includeSpecial: false, now: day(0))
        let confirmationIDs = Set(confirmations.map(\.id))
        let queuedConfirmations = queue.filter(confirmationIDs.contains)
        XCTAssertEqual(queuedConfirmations.count, 7, "no more 確認題 than the daily cap")
        XCTAssertTrue(queue.contains(mistake.id))
        XCTAssertEqual(Set(queue), Set(summary.plan.reviewIDs.filter { bank.byID[$0]?.subject == a }.prefix(StudyStore.subjectSessionSize)))

        // Answer the whole session correctly through the real commit path: every answer counts toward today's goal.
        XCTAssertEqual(summary.correctToday, 0)
        for id in queue {
            store.commit(question: bank.byID[id]!, chosen: "A", correct: true, unsure: false, reason: nil, now: day(0, hour: 10))
        }
        let after = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(0, hour: 11))
        XCTAssertEqual(after.correctToday, queue.count)

        // The session logs its own answer source and still counts as a daily session.
        let request = SessionRequest(queue: queue, doneBefore: 0, isDaily: true, isSubject: true)
        XCTAssertTrue(request.isDaily)
        XCTAssertTrue(request.isSubject)
        XCTAssertEqual(UsageLog.answerSource("subject"), "subject")
    }
}
