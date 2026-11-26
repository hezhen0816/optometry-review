import XCTest
@testable import OptometryReview

final class SubjectAnalysisTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }
    private func attempt(_ id: String, _ d: Double, _ correct: Bool, year: Int? = 112) -> SubjectAnalysis.Attempt {
        .init(questionID: id, timestamp: day(d), correct: correct, year: year)
    }

    func testScoreTrendKeepsUncountedAndLatestUsesCountedOnly() {
        let exams: [SubjectAnalysis.Exam] = [
            .init(date: day(3), score: 48, counted: true, seconds: []),
            .init(date: day(1), score: 36, counted: true, seconds: []),
            .init(date: day(2), score: 90, counted: false, seconds: []),
        ]
        let trend = SubjectAnalysis.scoreTrend(exams)
        XCTAssertEqual(trend.map(\.score), [36, 90, 48])
        XCTAssertEqual(trend.map(\.counted), [true, false, true])
        let latest = SubjectAnalysis.latestCounted(trend)
        XCTAssertEqual(latest?.latest, 48)
        XCTAssertEqual(latest?.previous, 36)
        XCTAssertNil(SubjectAnalysis.latestCounted([.init(date: day(0), score: 10, counted: false)]))
    }

    func testYearRatesAndWeakestTwo() {
        func answers(_ year: Int, correct: Int, wrong: Int) -> [SubjectAnalysis.Attempt] {
            (0..<correct).map { attempt("\(year)c\($0)", 0, true, year: year) }
                + (0..<wrong).map { attempt("\(year)w\($0)", 0, false, year: year) }
        }
        let attempts = answers(106, correct: 3, wrong: 3) + answers(108, correct: 0, wrong: 5)
            + answers(110, correct: 4, wrong: 1) + answers(111, correct: 3, wrong: 3)
            + answers(112, correct: 0, wrong: 2) + [attempt("g", 0, true, year: nil)]
        let rates = SubjectAnalysis.yearRates(attempts)
        XCTAssertEqual(rates.map(\.year), Array(106...115))
        XCTAssertEqual(rates.first?.percent, 50)
        XCTAssertNil(rates.first { $0.year == 107 }?.percent)
        // 112 is 0 % but has only 2 answers; 108 is 0 %, then 106 and 111 tie at 50 %: the earlier year wins.
        XCTAssertEqual(SubjectAnalysis.weakestYears(rates), [106, 108])
        // Fewer than three years with enough answers: nothing stands out.
        XCTAssertEqual(SubjectAnalysis.weakestYears(SubjectAnalysis.yearRates(answers(106, correct: 1, wrong: 5)
            + answers(108, correct: 0, wrong: 5) + answers(110, correct: 0, wrong: 4))), [])
    }

    func testPercentBelowAllCorrectShowsAtMost99() {
        XCTAssertEqual(SubjectAnalysis.percent(correct: 199, total: 200), 99)
        XCTAssertEqual(SubjectAnalysis.percent(correct: 200, total: 200), 100)
        XCTAssertEqual(SubjectAnalysis.percent(correct: 1, total: 3), 33)
        XCTAssertNil(SubjectAnalysis.percent(correct: 0, total: 0))
        XCTAssertEqual(UnitAccuracy.Rate(correct: 299, total: 300).percent, 99)
    }

    func testStatusReasonsPaceAndFrequentWrong() {
        let cards: [SubjectAnalysis.Card] = [
            .init(isScheduled: true, isDue: true, mastered: false, reason: "粗心"),
            .init(isScheduled: true, isDue: true, mastered: true, reason: "背錯"),
            .init(isScheduled: true, isDue: false, mastered: false, reason: "粗心"),
            .init(isScheduled: true, isDue: false, mastered: true, reason: nil),
            .init(isScheduled: false, isDue: false, mastered: false, reason: nil),
        ]
        XCTAssertEqual(SubjectAnalysis.statusCounts(cards), .init(due: 1, learning: 1, mastered: 2))
        let reasons = SubjectAnalysis.reasonCounts(cards)
        XCTAssertEqual(reasons.map(\.reason), MistakeReason.all)
        XCTAssertEqual(reasons.map(\.count), [0, 2, 0, 0], "only open mistakes count")

        XCTAssertNil(SubjectAnalysis.averageSeconds([.init(date: day(0), score: 0, counted: true, seconds: [0, 0])]))
        XCTAssertEqual(SubjectAnalysis.averageSeconds([.init(date: day(0), score: 0, counted: true, seconds: [60, 0, 90]),
                                                       .init(date: day(1), score: 0, counted: true, seconds: [90])]), 80)

        let attempts = [attempt("x", 0, false), attempt("x", 1, false), attempt("x", 2, true),
                        attempt("y", 0, false), attempt("y", 3, false), attempt("y", 4, false),
                        attempt("z", 0, false), attempt("w", 0, false), attempt("w", 5, false)]
        let often = SubjectAnalysis.frequentWrong(attempts)
        XCTAssertEqual(often.map(\.questionID), ["y", "w", "x"])
        XCTAssertEqual(often.map(\.wrongCount), [3, 2, 2])
    }

    func testAccuracyClassifiesAgainstFullHistory() {
        let attempts = [attempt("a", 0, false), attempt("a", 40, true), attempt("b", 41, true), attempt("c", 42, false)]
        let r = SubjectAnalysis.accuracy(attempts, since: day(35))
        XCTAssertEqual(r.new, .init(correct: 1, total: 2))
        XCTAssertEqual(r.review, .init(correct: 1, total: 1))
    }

    func testWeakUnitsThresholdOrderTiesAndCap() {
        func unit(_ id: String) -> ConceptUnit { ConceptUnit(id: id, subject: "S", name: id) }
        let units = ["S-1.1", "S-1.2", "S-1.9", "S-1.10", "S-2.1", "S-2.2"].map(unit)
        let rates: [String: UnitAccuracy.Rate] = [
            "S-1.1": .init(correct: 0, total: 4),   // below the threshold
            "S-1.2": .init(correct: 4, total: 5),   // 80 %
            "S-1.10": .init(correct: 2, total: 5),  // 40 %
            "S-1.9": .init(correct: 4, total: 10),  // 40 %: ties 1.10, the lower code comes first
            "S-2.1": .init(correct: 3, total: 10),  // 30 %
            "S-2.2": .init(correct: 3, total: 6),   // 50 %, cut by the cap
            "T-1.1": .init(correct: 0, total: 9),   // another subject
        ]
        let weak = SubjectAnalysis.weakUnits(units, rates: rates, questionCounts: ["S-2.1": 8, "S-1.9": 10])
        XCTAssertEqual(weak.map(\.unit.id), ["S-2.1", "S-1.9", "S-1.10"])
        XCTAssertEqual(weak.map(\.rate.total), [10, 10, 5])
        XCTAssertEqual(weak.map(\.fewQuestions), [true, false, true])
        XCTAssertEqual(SubjectAnalysis.weakUnits(units, rates: [:], questionCounts: [:]), [])
        XCTAssertEqual(SubjectAnalysis.weakUnits([unit("S-1.1")], rates: rates, questionCounts: [:]), [],
                       "four answers are not enough")
        XCTAssertEqual(SubjectAnalysis.weakUnits([unit("S-1.2")], rates: rates, questionCounts: [:]).map(\.unit.id), ["S-1.2"],
                       "five answers qualify even at a high accuracy")
    }
}
