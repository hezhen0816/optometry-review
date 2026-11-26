import XCTest
@testable import OptometryReview

final class PracticeScopeTests: XCTestCase {
    private func q(_ id: String, subject: String = "視覺光學", year: Int = 115, unit: String? = "視覺光學-1.4") -> Question {
        Question(id: id, code: "C\(year)", year: year, examKind: ExamKind.general, subject: subject, number: 1, stem: "測試",
                 options: ["A": "a", "B": "b", "C": "c", "D": "d"], answer: ["A"], originalAnswer: "A", corrected: false,
                 correctionNote: nil, allCredit: false, hasFigure: false, needsReview: false,
                 concepts: unit.map { [$0, "視覺光學-1.1"] } ?? [])
    }

    func testScopeFiltersSubjectYearsAndPrimaryUnit() {
        let a = q("a", year: 110), b = q("b", year: 115, unit: "視覺光學-1.1"), c = q("c", subject: "視光學", year: 112, unit: "視光學-1.1")
        var scope = PracticeScope.all
        XCTAssertTrue(scope.isAll)
        XCTAssertEqual(scope.filter([a, b, c]).count, 3)
        XCTAssertEqual(scope.label { _ in nil }, "全部題庫")
        scope.years = YearSelection(mode: .range, from: 111, to: 115)
        XCTAssertEqual(scope.filter([a, b, c]).map(\.id), ["b", "c"])
        scope.setSubject("視覺光學")
        XCTAssertEqual(scope.filter([a, b, c]).map(\.id), ["b"])
        XCTAssertEqual(scope.label { _ in nil }, "視覺光學 ・ 111–115 年")
        // Units match the primary concept only (a's secondary is 1.1).
        scope.years = .all
        scope.units = ["視覺光學-1.1"]
        XCTAssertEqual(scope.filter([a, b, c]).map(\.id), ["b"])
        XCTAssertEqual(scope.label { $0 == "視覺光學-1.1" ? "眼成像關係" : nil }, "視覺光學 ・ 眼成像關係")
        scope.setSubject("視光學")
        XCTAssertTrue(scope.units.isEmpty, "units belong to one subject")
        XCTAssertEqual(scope.filter([a, b, c]).map(\.id), ["c"])
    }

    func testToggleUnitsAndYearNormalization() {
        var scope = PracticeScope(subject: "視覺光學")
        scope.toggleUnit("u1", among: ["u1", "u2"])
        XCTAssertEqual(scope.units, ["u1"])
        scope.toggleUnit("u2", among: ["u1", "u2"])
        XCTAssertTrue(scope.units.isEmpty, "every unit selected is the same as all")
        XCTAssertEqual(PracticeScope(subject: "視覺光學", units: ["a", "b"]).label { _ in nil }, "視覺光學 ・ 2 個單元")
        let years = [106, 110, 115]
        XCTAssertEqual(YearSelection(mode: .range, from: 999, to: 1).normalized(years: years), YearSelection(mode: .range, from: 106, to: 115))
        XCTAssertEqual(YearSelection(mode: .single).normalized(years: years).from, 115)
        XCTAssertEqual(YearSelection(mode: .single, from: 110, to: 110).label, "110 年")
        XCTAssertNil(YearSelection.all.label)
    }

    func testCustomPracticeKindsSizeAndOrder() {
        let pool = (1...6).map { q("q\($0)", year: 110 + $0 % 2) }
        let history = CustomPractice.History(seen: ["q1", "q2", "q3"], openOrder: ["q3", "q1"])
        var choice = CustomPracticeChoice(kind: .unseen, size: 10)
        XCTAssertEqual(Set(CustomPractice.matches(pool: pool, choice: choice, history: history).map(\.id)), ["q4", "q5", "q6"])
        choice.kind = .missed
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(CustomPractice.queue(pool: pool, choice: choice, history: history, using: &rng), ["q3", "q1"],
                       "未熟練錯題 by urgency")
        choice.kind = .all
        choice.size = 4
        XCTAssertEqual(CustomPractice.queue(pool: pool, choice: choice, history: history, using: &rng).count, 4)
        XCTAssertEqual(choice.take(6), 4)
        choice.size = 0
        XCTAssertEqual(choice.take(6), 6)
        choice.scope.years = YearSelection(mode: .single, from: 111, to: 111)
        XCTAssertEqual(CustomPractice.matches(pool: pool, choice: choice, history: history).count, 3)
        XCTAssertEqual(CustomPractice.unitCounts(pool: pool, choice: choice, history: history), ["視覺光學-1.4": 3])
        choice.scope.years = YearSelection(mode: .single, from: 108, to: 108)
        XCTAssertTrue(CustomPractice.queue(pool: pool, choice: choice, history: history, using: &rng).isEmpty)
    }

    func testStoredChoicesRoundTripAndUnitNames() {
        let defaults = UserDefaults(suiteName: "opto.tests.\(UUID())")!
        XCTAssertEqual(ScopeStore.custom(defaults), CustomPracticeChoice())
        var choice = CustomPracticeChoice(scope: PracticeScope(subject: "低視力學", units: ["低視力學-1.2"]), kind: .missed, size: 0)
        choice.scope.years = YearSelection(mode: .range, from: 110, to: 115)
        ScopeStore.setCustom(choice, defaults: defaults)
        XCTAssertEqual(ScopeStore.custom(defaults), choice)
        XCTAssertEqual(ScopeStore.daily(defaults), .all, "the two scopes are stored apart")

        XCTAssertEqual(ConceptUnit.shortName("鏡片光學與特性(光學矯正鏡片、隱形眼鏡)"), "鏡片光學與特性")
        XCTAssertEqual(ConceptUnit.shortName("低視力光學原理、檢測與處理"), "低視力光學原理、檢測與處理")
        let json = #"{"subjects": {"視覺光學": [{"id": "視覺光學-1.7", "name": "特殊鏡片(例如：高折射率、屈光參差、像差等)"}]}}"#
        let units = ConceptUnit.load(json: Data(json.utf8))
        XCTAssertEqual(units, [ConceptUnit(id: "視覺光學-1.7", subject: "視覺光學", name: "特殊鏡片")])
    }

    func testMistakeFilterYearsUnitsAndActiveCount() {
        var f = MistakeFilter()
        XCTAssertEqual(f.activeCount(saved: false), 0)
        f.years = YearSelection(mode: .range, from: 110, to: 115)
        f.units = ["視覺光學-1.4"]
        XCTAssertTrue(f.matches(q("a", year: 112), reason: nil, saved: false), "units are ignored without a subject")
        f.setSubject("視覺光學")
        f.units = ["視覺光學-1.4"]
        f.reason = "粗心"
        f.mastered = true
        XCTAssertEqual(f.activeCount(saved: false), 5)
        XCTAssertEqual(f.activeCount(saved: true), 3, "☆ view has subject, years and units only")
        XCTAssertTrue(f.matches(q("a", year: 112), reason: "粗心", saved: false))
        XCTAssertFalse(f.matches(q("a", year: 109), reason: "粗心", saved: false))
        XCTAssertFalse(f.matches(q("b", year: 112, unit: "視覺光學-1.1"), reason: "粗心", saved: false))
        XCTAssertTrue(f.matches(q("b", year: 112, unit: "視覺光學-1.1"), reason: "粗心", saved: false, ignoringUnits: true))
        XCTAssertTrue(f.matches(q("a", year: 112), reason: nil, saved: true))
        let cleared = f.clearingSheet(saved: false)
        XCTAssertEqual(cleared.activeCount(saved: false), 0)
        XCTAssertEqual(cleared.subject, MistakeFilter.all, "the subject lives in the sheet now")
        XCTAssertTrue(cleared.units.isEmpty)
        XCTAssertTrue(f.clearingSheet(saved: true).mastered, "☆ reset leaves the hidden filters alone")
    }

    func testMistakeFilterTagsAndRemoval() {
        let units = [ConceptUnit(id: "視覺光學-1.1", subject: "視覺光學", name: "折射"),
                     ConceptUnit(id: "視覺光學-1.4", subject: "視覺光學", name: "稜鏡")]
        var f = MistakeFilter()
        XCTAssertEqual(f.tags(saved: false, units: units), [], "no tags when nothing is active")
        f.setSubject("視覺光學")
        f.years = YearSelection(mode: .range, from: 110, to: 115)
        f.units = ["視覺光學-1.4", "視覺光學-1.1"]
        f.reason = "粗心"
        f.mastered = true
        let tags = f.tags(saved: false, units: units)
        XCTAssertEqual(tags.map(\.kind), [.subject, .years, .unit("視覺光學-1.1"), .unit("視覺光學-1.4"), .reason, .mastered])
        XCTAssertEqual(tags.map(\.label)[0], "視覺光學")
        XCTAssertEqual(tags.map(\.label)[2...], ["折射", "稜鏡", "粗心", "已熟練"])
        XCTAssertEqual(tags.count, f.activeCount(saved: false), "button count matches the tags")
        XCTAssertEqual(f.tags(saved: true, units: units).map(\.kind),
                       [.subject, .years, .unit("視覺光學-1.1"), .unit("視覺光學-1.4")], "☆ view hides 錯因 and 已熟練")

        var g = f
        g.remove(.unit("視覺光學-1.4"))
        XCTAssertEqual(g.units, ["視覺光學-1.1"])
        XCTAssertEqual(g.subject, "視覺光學", "removing a unit keeps the rest")
        g.remove(.reason)
        XCTAssertFalse(g.reasonActive)
        XCTAssertTrue(g.mastered)
        g.remove(.years)
        XCTAssertEqual(g.years.mode, .all)
        g.remove(.subject)
        XCTAssertEqual(g.subject, MistakeFilter.all)
        XCTAssertTrue(g.units.isEmpty, "units go with their subject")
        g.remove(.mastered)
        XCTAssertEqual(g.tags(saved: false, units: units), [])
    }
}
