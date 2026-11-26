import XCTest
import SwiftData
@testable import OptometryReview

final class ScoreCountingTests: XCTestCase {
    private func exam(mode: ExamMode = .random, count: Int = 50, answered: Int, score: Int = 60,
                      days: Double = 0, subject: String = Subjects.all[0]) -> MockExam {
        let date = Date(timeIntervalSince1970: 1_000_000 + days * 86_400)
        let exam = MockExam(subject: subject, mode: mode, paperCode: nil, title: mode.rawValue,
                            questionIDs: (0..<count).map { "q\($0)" }, now: date)
        exam.answers = (0..<count).map { $0 < answered ? "A" : "" }
        exam.score = score
        exam.finishedAt = date
        return exam
    }

    func testScoreThresholdAndMistakeExclusion() {
        XCTAssertFalse(exam(answered: 39).countsTowardScores)
        XCTAssertTrue(exam(answered: 40).countsTowardScores)
        XCTAssertFalse(exam(mode: .mistakes, answered: 50).countsTowardScores)
        XCTAssertFalse(exam(count: 3, answered: 2).countsTowardScores)
        XCTAssertTrue(exam(count: 3, answered: 3).countsTowardScores)
        XCTAssertFalse(exam(count: 0, answered: 0).countsTowardScores)
    }

    @MainActor
    func testAllScoreSummaryPathsIgnoreUncountedExamsAndKeepHistory() throws {
        let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let exams = [exam(answered: 40, score: 50), exam(answered: 50, score: 70, days: 1),
                     exam(answered: 3, score: 2, days: 2), exam(mode: .mistakes, answered: 50, score: 10, days: 3)]
        for exam in exams { container.mainContext.insert(exam) }
        let store = StudyStore(context: container.mainContext)
        let summary = ScoreSummary(exams: store.finishedExams())
        XCTAssertEqual(store.finishedExams().count, 4)
        XCTAssertEqual(summary.entries, store.scoreEntries())
        XCTAssertEqual(summary.entries.count, 2)
        XCTAssertEqual(summary.latest[Subjects.all[0]], 70)
        XCTAssertEqual(summary.previous[Subjects.all[0]], 50)
        XCTAssertEqual(summary.series.map(\.average), [50, 70])
        XCTAssertEqual(summary.average, 70)
        XCTAssertEqual(summary.averageDelta, 20)
        XCTAssertEqual(summary.projection, .missing(Array(Subjects.all.dropFirst())))
        let unfinished = exam(answered: 50)
        unfinished.finishedAt = nil
        XCTAssertTrue(ScoreHistory.entries(from: [unfinished]).isEmpty)
    }

    func testLatestAndSeriesIgnoreUncountedEntries() {
        let entries = [ScoreHistory.Entry(subject: "S", score: 80, date: .distantPast),
                       ScoreHistory.Entry(subject: "S", score: 0, date: .now, countsTowardScores: false)]
        XCTAssertEqual(ScoreHistory.latest(entries), ["S": 80])
        XCTAssertTrue(ScoreHistory.previous(entries).isEmpty)
        XCTAssertEqual(ScoreHistory.averageSeries(entries).map(\.average), [80])
    }

    func testFullMockSubjectsUseSameEligibilityAndProjection() {
        let exams = Subjects.all.map { exam(answered: 40, score: 60, subject: $0) }
        for exam in exams { exam.fullMockID = UUID() }
        XCTAssertEqual(ScoreSummary(exams: exams).projection, .pass(average: 60))
        exams[4].answers = Array(repeating: "", count: 50)
        XCTAssertEqual(ScoreSummary(exams: exams).projection, .missing([Subjects.all[4]]))
    }

    #if DEBUG
    @MainActor
    func testEveryDemoSeedProducesEligibleMocks() throws {
        var questions: [Question] = []
        var papers: [Paper] = []
        for (code, year) in [("110111", 110), ("111110", 111), ("112110", 112), ("113100", 113), ("114100", 114), ("115100", 115)] {
            for subject in Subjects.all {
                let items = (1...50).map { number in
                    Question(id: Question.makeID(code: code, subject: subject, number: number),
                             code: code, year: year, examKind: ExamKind.general, subject: subject,
                             number: number, stem: "虛構測試題 \(number)",
                             options: ["A": "甲", "B": "乙", "C": "丙", "D": "丁"], answer: ["A"],
                             originalAnswer: nil, corrected: false, correctionNote: nil, allCredit: false,
                             hasFigure: false, needsReview: false, calculatorAllowed: false, concepts: [])
                }
                questions.append(contentsOf: items)
                papers.append(Paper(code: code, year: year, examKind: ExamKind.general, sessionNote: nil,
                                    subject: subject, fileCode: "demo", paperCode: nil, calculatorAllowed: false,
                                    questionIDs: items.map(\.id), hasCorrectedQuestions: false))
            }
        }
        let bank = QuestionBank(questions: questions, papers: papers)
        for args in [["-seedMocks"], ["-seedFullMock", "pass"], ["-seedFullMock", "fail"],
                     ["-seedFullMock", "progress"], ["-seedDemo"], ["-seedDemoLight"]] {
            let container = try StudyDataStore.open(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let defaults = UserDefaults(suiteName: "opto.seed.tests.\(UUID())")!
            DebugLaunch.apply(container: container, bank: bank, arguments: args, defaults: defaults)
            let exams = try container.mainContext.fetch(FetchDescriptor<MockExam>())
            XCTAssertFalse(exams.isEmpty, args.joined(separator: " "))
            XCTAssertTrue(exams.allSatisfy(\.countsTowardScores), args.joined(separator: " "))
            XCTAssertFalse(ScoreSummary(exams: exams).isEmpty)
            let records = try container.mainContext.fetch(FetchDescriptor<QuestionRecord>())
            XCTAssertTrue(records.allSatisfy { $0.fsrsVersion == StudyReplay.version })
            for exam in exams where exam.finishedAt != nil {
                for (index, id) in exam.questionIDs.enumerated() where !exam.answers[index].isEmpty {
                    XCTAssertTrue(records.first { $0.questionID == id }?.attempts?.contains {
                        $0.timestamp == exam.finishedAt && $0.source == AttemptRecord.examSource
                    } == true, "Finished mock answer missing from FSRS history")
                }
            }
            if args.contains("-seedDemoLight") {
                let value = defaults.double(forKey: SettingsKey.examDate)
                let scheduler = Scheduler(examDate: Date(timeIntervalSince1970: value))
                let store = StudyStore(context: container.mainContext, scheduler: scheduler, defaults: defaults, usageSink: { _, _ in })
                let backlog = store.todaySummary(bank: bank, includeSpecial: false, goal: 20).dueCount
                XCTAssertTrue((10...20).contains(backlog), "DemoLight backlog: \(backlog)")
                XCTAssertTrue(records.contains { $0.isMastered(using: scheduler) })
            }
            if args.contains("fail") {
                let full = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<FullMock>()).first)
                let scores = StudyStore(context: container.mainContext).subjectExams(of: full).map(\.score)
                XCTAssertTrue(scores.contains(0))
                XCTAssertFalse(FullMockJudgment(scores: scores).passed)
            }
        }
    }
    #endif
}
