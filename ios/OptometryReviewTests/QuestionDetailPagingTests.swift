import XCTest
import SwiftData
@testable import OptometryReview

final class QuestionDetailPagingTests: XCTestCase {
    private func q(_ id: String, answer: String = "A") -> Question {
        Question(id: id, code: "115100", year: 115, examKind: ExamKind.general,
                 subject: Subjects.all[0], number: 1, stem: "test", options: ["A": "a", "B": "b", "C": "c", "D": "d"],
                 answer: [answer], originalAnswer: answer, corrected: false, correctionNote: nil,
                 allCredit: false, hasFigure: false, needsReview: false)
    }

    // MARK: Paging

    func testPagerStepsWithinBoundsInListOrder() {
        var p = QuestionPager(ids: ["c", "a", "b"], current: "a")
        XCTAssertEqual(p.index, 1)
        XCTAssertTrue(p.hasPrevious)
        XCTAssertTrue(p.hasNext)
        XCTAssertTrue(p.step(1))
        XCTAssertEqual(p.current, "b")
        XCTAssertFalse(p.hasNext)
        XCTAssertFalse(p.step(1))
        XCTAssertEqual(p.current, "b")
        XCTAssertTrue(p.step(-1))
        XCTAssertTrue(p.step(-1))
        XCTAssertEqual(p.current, "c")
        XCTAssertFalse(p.hasPrevious)
        XCTAssertFalse(p.step(-1))
        XCTAssertEqual(p.index, 0)
    }

    func testPagerWithoutListOrMissingCurrentDoesNotPage() {
        for ids in [[], ["x", "y"]] {
            let p = QuestionPager(ids: ids, current: "a")
            XCTAssertEqual(p.ids, ["a"])
            XCTAssertFalse(p.hasPrevious)
            XCTAssertFalse(p.hasNext)
        }
    }

    // MARK: Answer visibility

    func testDefaultShowsAnsweredAndHidesUnanswered() {
        let v = DetailAnswerVisibility()
        XCTAssertTrue(v.shows(answered: true, hideByDefault: false))
        XCTAssertFalse(v.shows(answered: false, hideByDefault: false))
    }

    func testHideByDefaultSettingHidesEveryQuestion() {
        let v = DetailAnswerVisibility()
        XCTAssertFalse(v.shows(answered: true, hideByDefault: true))
        XCTAssertFalse(v.shows(answered: false, hideByDefault: true))
    }

    func testToggleAffectsCurrentQuestionAndResetsOnPaging() {
        var v = DetailAnswerVisibility()
        v.toggle(answered: false, hideByDefault: false)          // 顯示答案 on an unanswered question
        XCTAssertTrue(v.shows(answered: false, hideByDefault: false))
        v.toggle(answered: false, hideByDefault: false)          // 隱藏答案
        XCTAssertFalse(v.shows(answered: false, hideByDefault: false))
        v.reset()                                                // paged to an answered question: its own default
        XCTAssertTrue(v.shows(answered: true, hideByDefault: false))
        v.toggle(answered: true, hideByDefault: false)           // 隱藏答案 on it
        XCTAssertFalse(v.shows(answered: true, hideByDefault: false))
        v.reset()                                                // paged again
        XCTAssertTrue(v.shows(answered: true, hideByDefault: false))
        XCTAssertFalse(v.shows(answered: false, hideByDefault: false))
    }

    /// 「顯示答案」 is view state only: the question stays unanswered (no record, no 看解答 entry).
    @MainActor
    func testRevealDoesNotRecordAnAttempt() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, scheduler: Scheduler())
        let history = QuestionHistory.load(questionID: "q", store: store)
        XCTAssertTrue(history.entries.isEmpty)
        var v = DetailAnswerVisibility()
        v.toggle(answered: !history.entries.isEmpty, hideByDefault: false)
        XCTAssertTrue(v.shows(answered: !history.entries.isEmpty, hideByDefault: false))
        XCTAssertNil(store.record(for: "q"))
        XCTAssertTrue(QuestionHistory.load(questionID: "q", store: store).entries.isEmpty)
    }

    // MARK: Unit page 「練這 N 題」

    func testUnitPagePracticeCountFollowsSegment() {
        let qs = ["a", "b", "c", "d"].map { q($0) }
        let history = CustomPractice.History(seen: ["a", "b", "c"], openOrder: ["b"])
        func ids(_ f: UnitDetailView.Filter) -> [String] {
            UnitDetailView.shown(qs, filter: f, history: history).map(\.id)
        }
        XCTAssertEqual(ids(.wrong), ["b"])
        XCTAssertEqual(ids(.unseen), ["d"])
        XCTAssertEqual(ids(.all), ["a", "b", "c", "d"])
    }

    // MARK: Coach mark

    func testTipShowsOnceAndIsResettable() {
        let defaults = UserDefaults(suiteName: "QuestionDetailPagingTests.tip")!
        defaults.removePersistentDomain(forName: "QuestionDetailPagingTests.tip")
        let key = SettingsKey.tipUnitsShown
        XCTAssertTrue(SettingsKey.allTips.contains(key), "-tipsShown and 設定 reset cover it")
        XCTAssertTrue(SettingsKey.tipPending(key, defaults: defaults))
        SettingsKey.markTipShown(key, defaults: defaults)
        XCTAssertFalse(SettingsKey.tipPending(key, defaults: defaults))
        defaults.removePersistentDomain(forName: "QuestionDetailPagingTests.tip")
    }
}
