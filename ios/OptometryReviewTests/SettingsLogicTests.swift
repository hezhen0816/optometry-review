import XCTest
import SwiftData
@testable import OptometryReview

final class SettingsLogicTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func day(_ offset: Int = 0, hour: Int = 9) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour))!
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    private func q(_ id: String, year: Int, special: Bool = false) -> Question {
        Question(id: id, code: id, year: year, examKind: special ? ExamKind.special : ExamKind.general,
                 subject: Subjects.all[0], number: 1, stem: "測試", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                 answer: ["A"], originalAnswer: "A", corrected: false, correctionNote: nil,
                 allCredit: false, hasFigure: false, needsReview: false)
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "opto.tests.\(UUID())")! }

    func testDailyScopeNarrowsNewPoolAndSpecialPool() {
        let bank = QuestionBank(questions: [q("old", year: 106), q("new", year: 115), q("special", year: 110, special: true)])
        let defaults = defaults()
        XCTAssertEqual(bank.availableYears, [106, 110, 115])
        XCTAssertEqual(ScopeStore.daily(defaults), .all)
        XCTAssertEqual(bank.newQuestionPool(includeSpecial: false, defaults: defaults).count, 2)
        XCTAssertEqual(bank.newQuestionPool(includeSpecial: true, defaults: defaults).count, 3)
        var scope = PracticeScope.all
        scope.years = YearSelection(mode: .single, from: 110, to: 110)
        ScopeStore.setDaily(scope, defaults: defaults)
        XCTAssertTrue(bank.newQuestionPool(includeSpecial: false, defaults: defaults).isEmpty)
        XCTAssertEqual(bank.newQuestionPool(includeSpecial: true, defaults: defaults).map(\.id), ["special"])
    }

    func testLegacyYearRangeMigratesOnceIntoDailyScope() {
        let years = [106, 110, 115]
        let defaults = defaults()
        defaults.set(110, forKey: SettingsKey.yearFrom)
        defaults.set(999, forKey: SettingsKey.yearTo)
        ScopeStore.migrateLegacyYears(defaults: defaults, availableYears: years)
        XCTAssertEqual(ScopeStore.daily(defaults).years, YearSelection(mode: .range, from: 110, to: 115))
        XCTAssertNil(defaults.object(forKey: SettingsKey.yearFrom))
        XCTAssertNil(defaults.object(forKey: SettingsKey.yearTo))
        // A full range means every year; a stored scope is never overwritten.
        let full = self.defaults()
        full.set(106, forKey: SettingsKey.yearFrom); full.set(115, forKey: SettingsKey.yearTo)
        ScopeStore.migrateLegacyYears(defaults: full, availableYears: years)
        XCTAssertEqual(ScopeStore.daily(full), .all)
        let kept = self.defaults()
        var scope = PracticeScope.all
        scope.subject = Subjects.all[1]
        ScopeStore.setDaily(scope, defaults: kept)
        kept.set(115, forKey: SettingsKey.yearFrom)
        ScopeStore.migrateLegacyYears(defaults: kept, availableYears: years)
        XCTAssertEqual(ScopeStore.daily(kept), scope)
        XCTAssertNil(kept.object(forKey: SettingsKey.yearFrom))
    }

    @MainActor
    func testDailyScopeDoesNotHideDueMistakesMocksOrExplicitPapers() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = defaults()
        let old = q("old", year: 106), oldFresh = q("oldFresh", year: 106), new = q("new", year: 115)
        let bank = QuestionBank(questions: [old, oldFresh, new])
        var scope = PracticeScope.all
        scope.years = YearSelection(mode: .single, from: 115, to: 115)
        ScopeStore.setDaily(scope, defaults: defaults)
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), defaults: defaults)
        store.commit(question: old, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-1))
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day())
        XCTAssertEqual(summary.plan.dueIDs, [old.id])
        XCTAssertEqual(summary.plan.newIDs, [new.id])
        XCTAssertEqual(summary.poolSize, 1); XCTAssertEqual(summary.seenInPool, 0)
        XCTAssertEqual(store.openMistakeIDs(subject: old.subject, bank: bank, includeSpecial: false), [old.id])
        // Mock exams draw from the whole active pool; the 今日 scope is for new daily questions only.
        let random = try XCTUnwrap(store.makeExam(subject: old.subject, mode: .random, paper: nil, bank: bank,
                                                 includeSpecial: false, now: day()))
        XCTAssertEqual(Set(random.questionIDs), [old.id, oldFresh.id, new.id])
        let focus = store.mistakeFocusIDs(subject: old.subject, bank: bank, includeSpecial: false)
        XCTAssertEqual(focus.first, old.id); XCTAssertTrue(focus.contains(oldFresh.id))
        let paper = Paper(code: old.code, year: 106, examKind: ExamKind.general, sessionNote: nil,
                          subject: old.subject, fileCode: "", paperCode: nil, calculatorAllowed: false,
                          questionIDs: [old.id, oldFresh.id], hasCorrectedQuestions: false)
        let explicit = try XCTUnwrap(store.makeExam(subject: old.subject, mode: .wholePaper, paper: paper,
                                                   bank: bank, includeSpecial: false, now: day()))
        XCTAssertEqual(explicit.questionIDs, paper.questionIDs)
    }

    @MainActor
    func testTodayFirstAttemptCountIncludesMocksButNotRepeatedReview() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler(calendar: calendar), defaults: defaults())
        let old = q("old", year: 115), fresh = q("fresh", year: 115), mock = q("mock", year: 115)
        let bank = QuestionBank(questions: [old, fresh, mock])
        store.commit(question: old, chosen: "B", correct: false, unsure: false, reason: nil, now: day(-1))
        for question in [old, fresh, fresh] {
            store.commit(question: question, chosen: "A", correct: true, unsure: false, reason: nil, now: day())
        }
        store.commit(question: mock, chosen: "A", correct: true, unsure: false, reason: nil,
                     source: AttemptRecord.examSource, now: day())
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day())
        XCTAssertEqual(summary.answeredToday, 2)
        XCTAssertEqual(summary.newAnsweredToday, 2)
        XCTAssertEqual(summary.seenInPool, 3)
        XCTAssertTrue(summary.goalMet(2)); XCTAssertFalse(summary.goalMet(20))
    }

    func testReminderDatesSkipTodayAtGoalOrAfterChosenTime() {
        let now = day(hour: 20)
        let dates = ReminderSchedule.dates(minutes: 21 * 60, goalMet: false, now: now, calendar: calendar)
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(dates.first, day(hour: 21))
        XCTAssertEqual(dates.last, day(6, hour: 21))
        let met = ReminderSchedule.dates(minutes: 21 * 60, goalMet: true, now: now, calendar: calendar)
        XCTAssertEqual(met.first, day(1, hour: 21)); XCTAssertEqual(met.last, day(7, hour: 21))
        let passed = ReminderSchedule.dates(minutes: 21 * 60, goalMet: false, now: day(hour: 21), calendar: calendar)
        XCTAssertEqual(passed, met)
        XCTAssertEqual(ReminderSchedule.dates(minutes: -1, goalMet: false, now: now, calendar: calendar).first, day(1, hour: 0))
    }

    func testReminderCalendarAcrossDSTAndYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20))!
        let dates = ReminderSchedule.dates(minutes: 21 * 60, goalMet: false, now: now, calendar: calendar)
        XCTAssertEqual(dates.count, 7)
        XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 21 })
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 25 * 3600)
        let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 22))!
        let next = ReminderSchedule.dates(minutes: 21 * 60, goalMet: false, now: end, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: next[0]), 2027)
        XCTAssertEqual(calendar.component(.day, from: next[0]), 1)
    }
}
