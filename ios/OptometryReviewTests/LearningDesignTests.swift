import XCTest
import SwiftData
@testable import OptometryReview

/// Milestone 3: option shuffling, exam-date scheduling, weekly goal, accuracy split, related questions,
/// unseen-first random mocks and the full-mock pass rule.
final class LearningDesignTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func start(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.startOfDay(for: day(y, m, d)) }

    private func q(_ id: String, options: [String: String]? = nil, answer: [String] = ["B"], subject: String = "視覺光學",
                   code: String = "T", number: Int = 1, stem: String = "題幹", optionsAsImage: Bool = false,
                   corrected: Bool = false, note: String? = nil, original: String? = nil) -> Question {
        var question = Question(id: id, code: code, year: 115, examKind: ExamKind.general, subject: subject, number: number,
                                stem: stem, options: options ?? ["A": "一", "B": "二", "C": "三", "D": "四"],
                                answer: answer, originalAnswer: original ?? answer.first, corrected: corrected,
                                correctionNote: note, allCredit: false, hasFigure: false, needsReview: false)
        question.optionsAsImage = optionsAsImage
        return question
    }

    // MARK: Shuffle eligibility

    func testCrossReferencePatternPinsOptionOrder() {
        for text in ["以上三者皆有可能，依照燈塔的值班表而定", "以上皆是", "以上皆非", "皆正確", "皆錯誤",
                     "A與B", "A 和 C", "B及D", "A、B", "C,D", "A，D", "以上都有可能", "以上各項", "選項甲"] {
            XCTAssertTrue(OptionShuffle.refersToOtherOptions(text), text)
        }
        for text in ["累積飛行 20 年以上的郵務機器人", "月球幣 1 萬元以上 5 萬元以下的運費", "紫光郵件分流器（PLMS）",
                     "+3.25D/-1.75D 星港測試鏡片", "月面燈罩（lunar lamp cover）", "PMMA 郵筒"] {
            XCTAssertFalse(OptionShuffle.refersToOtherOptions(text), text)
        }
    }

    func testEligibilityExcludesImagesEmptyOptionsAndCrossReferences() {
        XCTAssertTrue(OptionShuffle.isEligible(q("a")))
        XCTAssertFalse(OptionShuffle.isEligible(q("b", optionsAsImage: true)))
        XCTAssertFalse(OptionShuffle.isEligible(q("c", options: ["A": "一", "B": "", "C": "三", "D": "四"])))
        XCTAssertFalse(OptionShuffle.isEligible(q("d", options: ["A": "一", "B": "二", "C": "三", "D": "以上三者皆有可能"])))
        var rng = SeededGenerator(seed: 3)
        XCTAssertEqual(OptionShuffle.order(for: q("e", optionsAsImage: true), using: &rng), ["A", "B", "C", "D"])
    }

    func testShuffledOrderIsAPermutationAndRoundTrips() {
        var rng = SeededGenerator(seed: 11)
        var sawNonIdentity = false
        for _ in 0..<20 {
            let order = OptionShuffle.order(for: q("x"), using: &rng)
            XCTAssertEqual(Set(order), Set(Question.letters))
            XCTAssertEqual(OptionShuffle.decode(OptionShuffle.encode(order)), order)
            if order != Question.letters { sawNonIdentity = true }
        }
        XCTAssertTrue(sawNonIdentity)
        XCTAssertEqual(OptionShuffle.encode(Question.letters), "")
        XCTAssertEqual(OptionShuffle.decode(""), Question.letters)
        XCTAssertEqual(OptionShuffle.decode("AAB"), Question.letters, "invalid strings fall back to the original order")
    }

    func testAttemptStoresOriginalLetterAndGradesWithOriginalAnswer() {
        // Original answer B is shown in the third row ("C").
        let order = OptionOrder(shown: ["D", "A", "B", "C"])
        let question = q("y", answer: ["B"])
        XCTAssertEqual(order.displayedLetter(forOriginal: "B"), "C")
        let tapped = order.originalLetter(forDisplayed: "C")
        XCTAssertEqual(tapped, "B", "the attempt stores the original letter")
        XCTAssertTrue(Grading.isCorrect(chosen: tapped, question: question))
        XCTAssertFalse(Grading.isCorrect(chosen: order.originalLetter(forDisplayed: "B"), question: question))
        XCTAssertEqual(order.originalLetter(forDisplayed: "A"), "D")
    }

    func testCorrectedAnswerNoteMapsToShownLetters() {
        let order = OptionOrder(shown: ["D", "A", "B", "C"]) // B → C, D → A, A → B, C → D
        XCTAssertEqual(order.mapLetters(in: "答B或D或BD者均給分"), "答C或A或AC者均給分")
        XCTAssertEqual(order.mapLetters(in: "答 B 或 D 者給分"), "答 C 或 A 者給分")
        XCTAssertEqual(order.mapLetters(in: "（原公布答案 D）"), "（原公布答案 A）")
        XCTAssertEqual(order.mapLetters(in: "BRAO 與 Dk/L 不變"), "BRAO 與 Dk/L 不變", "letters inside words stay")
        XCTAssertEqual(OptionOrder.original.mapLetters(in: "答B或D"), "答B或D")
        let corrected = q("z", answer: ["B", "D"], corrected: true, note: "第6題答B或D或BD者均給分", original: "D")
        XCTAssertEqual(order.mapLetters(in: corrected.correctionSummary!), "答C或A或AC者均給分")
    }

    func testMixedMocksShuffleAndWholePapersKeepOriginalOrder() {
        let qs = (1...30).map { q("m\($0)") } + [q("img", optionsAsImage: true)]
        var rng = SeededGenerator(seed: 5)
        let mixed = ExamBuilder.optionOrders(for: qs, mode: .random, using: &rng)
        XCTAssertEqual(mixed.count, qs.count)
        XCTAssertTrue(mixed.contains { !$0.isEmpty })
        XCTAssertEqual(mixed.last, "", "image options stay in place")
        XCTAssertTrue(ExamBuilder.optionOrders(for: qs, mode: .wholePaper, using: &rng).allSatisfy(\.isEmpty))
    }

    // MARK: Exam-date scheduling

    func testCapNeverEarlierThanTomorrowAndIgnoredWhenExamPast() {
        let policy = ExamDatePolicy(examDate: start(2026, 10, 9), calendar: calendar)
        XCTAssertEqual(policy.adjust(due: start(2026, 10, 14), answeredAt: day(2026, 10, 7)), start(2026, 10, 8))
        let state = ReviewSchedule(stability: 7, difficulty: 6, reps: 2, lapses: 1,
                                   lastReview: day(2026, 10, 6), due: start(2026, 10, 14))
        let past = Scheduler(calendar: calendar, examDate: start(2026, 10, 1))
        let none = Scheduler(calendar: calendar)
        XCTAssertEqual(past.effectiveDue(state, now: day(2026, 10, 7)), state.due)
        XCTAssertEqual(none.effectiveDue(state, now: day(2026, 10, 7)), state.due)
    }

    func testFinalTwoWeeksMakesEveryOpenMistakeDueDaily() {
        let s = Scheduler(calendar: calendar, examDate: start(2026, 10, 20))
        var stored = ReviewSchedule(stability: 23, difficulty: 6, reps: 3, lapses: 1,
                                    lastReview: day(2026, 10, 3), due: start(2026, 10, 30))
        XCTAssertTrue(s.isDue(stored, on: day(2026, 10, 7)))
        stored.lastReview = day(2026, 10, 7, hour: 8)
        XCTAssertFalse(s.isDue(stored, on: day(2026, 10, 7, hour: 20)), "reviewed today, not due today")
        XCTAssertTrue(s.isDue(stored, on: day(2026, 10, 8)))
        stored.dueCorrectCount = 2
        XCTAssertFalse(s.isDue(stored, on: day(2026, 10, 8)), "already reviewed inside the pre-exam window")
        stored.dueCorrectCount = 0
        let far = Scheduler(calendar: calendar, examDate: start(2026, 11, 6))
        XCTAssertFalse(far.isDue(stored, on: day(2026, 10, 7)))
        XCTAssertEqual(far.effectiveDue(stored, now: day(2026, 10, 7)), start(2026, 10, 30))
        stored.due = start(2026, 11, 20)
        XCTAssertEqual(far.effectiveDue(stored, now: day(2026, 10, 7)), start(2026, 11, 3))
    }

    // MARK: Weekly goal

    func testWeekStartsMondayAndCountsOnlyDaysAtGoal() {
        // 2026-10-07 is a Wednesday; the week is 10/5 (Mon) … 10/11 (Sun).
        let now = day(2026, 10, 7, hour: 21)
        XCTAssertEqual(WeeklyGoal.weekStart(of: now, calendar: calendar), start(2026, 10, 5))
        XCTAssertEqual(WeeklyGoal.weekStart(of: day(2026, 10, 11), calendar: calendar), start(2026, 10, 5), "Sunday belongs to the week before")
        XCTAssertEqual(WeeklyGoal.weekStart(of: day(2026, 10, 12), calendar: calendar), start(2026, 10, 12))

        var attempts: [AttemptFact] = []
        func add(_ d: Date, _ n: Int, exam: Bool = false, prefix: String = "q") {
            for i in 0..<n { attempts.append(AttemptFact(questionID: "\(prefix)\(i)", timestamp: d, correct: true, fromExam: exam)) }
        }
        add(day(2026, 10, 4), 20)                       // Sunday of the previous week
        add(day(2026, 10, 5), 20)                       // Monday: reached
        add(day(2026, 10, 6), 12)                       // Tuesday: partial
        add(day(2026, 10, 6), 50, exam: true, prefix: "e") // mock answers do not count
        add(day(2026, 10, 7), 10)
        add(day(2026, 10, 7, hour: 20), 10)             // same 10 questions again: still 10 distinct
        add(day(2026, 10, 7, hour: 21), 10, prefix: "w") // 20 distinct → reached
        let counts = WeeklyGoal.goalCounts(attempts, calendar: calendar)
        XCTAssertEqual(counts[start(2026, 10, 6)], 12)
        XCTAssertEqual(WeeklyGoal.daysReached(counts: counts, goal: 20, now: now, calendar: calendar), 2)
        let week = WeeklyGoal.week(counts: counts, goal: 20, now: now, calendar: calendar)
        XCTAssertEqual(week.map(\.reached), [true, false, true, false, false, false, false])
        XCTAssertEqual(week.map(\.isFuture), [false, false, false, true, true, true, true])
    }

    func testHeatmapLevelsAndCells() {
        XCTAssertEqual([0, 1, 10, 11, 20, 21, 30, 31, 80].map { StudyHeatmap.level(count: $0, goal: 20) }, [0, 1, 1, 2, 2, 3, 3, 4, 4])
        let cells = StudyHeatmap.cells(counts: [start(2026, 10, 7): 25], goal: 20, now: day(2026, 10, 7), calendar: calendar)
        XCTAssertEqual(cells.count, 35)
        XCTAssertEqual(cells.first?.date, start(2026, 9, 7), "five Monday-start weeks")
        XCTAssertEqual(cells.first { $0.date == start(2026, 10, 7) }?.level, 3)
        XCTAssertNil(cells.last?.level, "future days have no level")
    }

    // MARK: New vs review accuracy

    func testFirstEverAttemptIsNewLaterAttemptsAreReview() {
        let d = { (n: Double) in Date(timeIntervalSince1970: 1_000_000 + n * 86_400) }
        let attempts = [
            AttemptFact(questionID: "a", timestamp: d(0), correct: false, fromExam: false), // new (before window)
            AttemptFact(questionID: "a", timestamp: d(40), correct: true, fromExam: false), // review
            AttemptFact(questionID: "b", timestamp: d(41), correct: true, fromExam: true),  // new (mock counts too)
            AttemptFact(questionID: "b", timestamp: d(42), correct: false, fromExam: false), // review
            AttemptFact(questionID: "c", timestamp: d(43), correct: false, fromExam: false), // new
            AttemptFact(questionID: "a", timestamp: d(44), correct: true, fromExam: false), // review
        ]
        let all = AccuracySplit.compute(attempts.reversed())
        XCTAssertEqual(all.new, .init(correct: 1, total: 3))
        XCTAssertEqual(all.review, .init(correct: 2, total: 3))
        let recent = AccuracySplit.compute(attempts, since: d(30))
        XCTAssertEqual(recent.new, .init(correct: 1, total: 2), "a's first attempt is outside the window and not re-labelled new")
        XCTAssertEqual(recent.review, .init(correct: 2, total: 3))
        XCTAssertEqual(recent.review.percent, 67)
        XCTAssertNil(AccuracySplit.Rate().percent)
    }

    // MARK: Related questions

    func testRelatedRankingIsDeterministicAndSkipsSameQuestionAndNeighbors() {
        let qs = [
            q("p1_1", options: ["A": "12 張", "B": "15 張", "C": "18 張", "D": "21 張"], code: "P1", number: 5,
              stem: "月球郵局的水晶蝸牛每盒裝三張紫色郵票，若要寄出五盒，總共要準備幾張紫色郵票？"),
            q("p1_2", code: "P1", number: 6, stem: "每盒裝三張紫色郵票，月球郵局的水晶蝸牛要寄出五盒，總共要準備幾張紫色郵票？"),
            q("p2_1", code: "P2", number: 21, stem: "月球郵局的水晶蝸牛有二十張紫色郵票，每盒裝五張，問總共有幾盒？"),
            q("p3_1", code: "P3", number: 30, stem: "月球郵局的水晶蝸牛每盒裝兩張紫色郵票，若要寄出六盒，總共要準備幾張紫色郵票？"),
            q("p4_1", code: "P4", number: 2, stem: "星港燈塔每到午夜會發出兩道綠光"),
            q("p5_1", code: "P5", number: 9, stem: "雪山觀景台的風速與積雪厚度的關係"),
        ]
        let index = RelatedIndex(questions: qs)
        let first = index.related(to: "p1_1")
        XCTAssertEqual(first, RelatedIndex(questions: qs.reversed()).related(to: "p1_1"), "independent of input order")
        XCTAssertFalse(first.contains("p1_1"))
        XCTAssertFalse(first.contains("p1_2"), "same-paper neighbor is skipped")
        XCTAssertEqual(first.first, "p3_1", "most similar wording first")
        XCTAssertFalse(first.contains("p4_1"), "unrelated wording stays below the threshold")
        XCTAssertLessThanOrEqual(first.count, 3)
        XCTAssertEqual(index.related(to: "p1_1"), first, "cached result is stable")
        XCTAssertEqual(index.related(to: "p1_1", allow: { $0 != "p3_1" }).first, "p2_1")
        XCTAssertEqual(index.related(to: "missing"), [])
    }

    // MARK: Random mix

    func testRandomMixPrefersUnseenAndFillsWithSeen() {
        let pool = (1...60).map { "q\($0)" }
        let seen = Set((1...30).map { "q\($0)" })
        var rng = SeededGenerator(seed: 9)
        let ids = ExamBuilder.randomMix(pool: pool, seen: seen, count: 50, using: &rng)
        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(Set(ids).count, 50)
        XCTAssertTrue(Set((31...60).map { "q\($0)" }).isSubset(of: Set(ids)), "all 30 unseen questions are used")
        XCTAssertEqual(ids.filter(seen.contains).count, 20, "seen questions only fill the gap")

        let manyUnseen = (1...120).map { "n\($0)" } + Array(seen)
        let ids2 = ExamBuilder.randomMix(pool: manyUnseen, seen: seen, count: 50, using: &rng)
        XCTAssertTrue(ids2.allSatisfy { !seen.contains($0) })
    }

    // MARK: Full mock

    func testFullMockPassNeedsAverageSixtyAndNoZero() {
        let pass = FullMockJudgment(scores: [70, 62, 62, 66, 48])
        XCTAssertEqual(pass.average, 61.6, accuracy: 0.001)
        XCTAssertTrue(pass.averageOK)
        XCTAssertTrue(pass.noZero)
        XCTAssertTrue(pass.passed)
        XCTAssertEqual(pass.averageIfLowestAt60?.index, 4)
        XCTAssertEqual(pass.averageIfLowestAt60?.average ?? 0, 64, accuracy: 0.001)

        let zero = FullMockJudgment(scores: [90, 90, 90, 90, 0])
        XCTAssertEqual(zero.average, 72)
        XCTAssertTrue(zero.averageOK)
        XCTAssertFalse(zero.noZero)
        XCTAssertFalse(zero.passed, "one subject at 0 fails even with a high average")

        let low = FullMockJudgment(scores: [60, 60, 60, 60, 58])
        XCTAssertFalse(low.averageOK)
        XCTAssertFalse(low.passed)
        XCTAssertTrue(FullMockJudgment(scores: [60, 60, 60, 60, 60]).passed, "exactly 60 passes")
        XCTAssertFalse(FullMockJudgment(scores: [80, 80]).passed, "needs all five subjects")
    }

    func testDefaultSessionIsNewestNotFullyTaken() {
        func session(_ code: String, _ year: Int, papers: Int = 5) -> ExamSession {
            ExamSession(code: code, year: year, examKind: ExamKind.general, label: "\(year) 年",
                        papers: (0..<papers).map { i in
                            Paper(code: code, year: year, examKind: ExamKind.general, sessionNote: nil, subject: Subjects.all[i],
                                  fileCode: "", paperCode: nil, calculatorAllowed: false, questionIDs: [], hasCorrectedQuestions: false)
                        })
        }
        let sessions = [session("115", 115), session("114", 114), session("113", 113, papers: 4), session("112", 112)]
        XCTAssertEqual(FullMockRules.defaultSession(sessions, fullyTaken: [])?.code, "115")
        XCTAssertEqual(FullMockRules.defaultSession(sessions, fullyTaken: ["115"])?.code, "114")
        XCTAssertEqual(FullMockRules.defaultSession(sessions, fullyTaken: ["115", "114"])?.code, "112", "incomplete sessions are skipped")
        XCTAssertEqual(FullMockRules.defaultSession(sessions, fullyTaken: ["115", "114", "112"])?.code, "115")
        XCTAssertEqual(FullMockRules.breakRemaining(startedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 120)), 480)
        XCTAssertEqual(FullMockRules.breakRemaining(startedAt: nil, now: .now), 0)
    }

    @MainActor
    func testFullMockScoresStayHiddenUntilAllFiveAreSubmitted() throws {
        let container = try ModelContainer(for: QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self,
                                           QuestionNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        var questions: [Question] = []
        var papers: [Paper] = []
        for (si, subject) in Subjects.all.enumerated() {
            let qs = (1...3).map { n in q("F_\(si)_\(n)", answer: ["A"], subject: subject, code: "F", number: n) }
            questions += qs
            papers.append(Paper(code: "F", year: 115, examKind: ExamKind.general, sessionNote: nil, subject: subject,
                                fileCode: "", paperCode: nil, calculatorAllowed: false, questionIDs: qs.map(\.id),
                                hasCorrectedQuestions: false))
        }
        let bank = QuestionBank(questions: questions, papers: papers)
        let store = StudyStore(context: context, scheduler: Scheduler(calendar: calendar))
        let session = PaperCatalog.sessions(papers, kind: ExamKind.general)[0]
        let full = store.startFullMock(session: session, now: day(2026, 10, 7))

        for i in 0..<5 {
            let exam = try XCTUnwrap(store.nextSubjectExam(of: full, bank: bank, now: day(2026, 10, 7, hour: 9 + i)))
            XCTAssertEqual(exam.subject, Subjects.all[i], "official subject order")
            XCTAssertTrue(exam.optionOrders.allSatisfy(\.isEmpty), "full mocks keep the original order")
            exam.answers = ["A", "B", ""]
            store.finish(exam: exam, bank: bank, elapsed: 600, auto: false, now: day(2026, 10, 7, hour: 9 + i))
            if i < 4 {
                XCTAssertNil(exam.finishedAt)
                XCTAssertNotNil(exam.submittedAt)
                XCTAssertTrue(store.allAttempts().isEmpty, "nothing recorded before the fifth subject")
                XCTAssertTrue(store.finishedExams().isEmpty, "scores stay hidden")
                XCTAssertNil(store.unfinishedExam(), "full-mock subjects are not single-mock resumes")
            }
        }
        XCTAssertNil(store.nextSubjectExam(of: full, bank: bank))
        store.completeFullMock(full, bank: bank, now: day(2026, 10, 7, hour: 15))
        XCTAssertTrue(full.isFinished)
        XCTAssertEqual(store.finishedExams().count, 5)
        XCTAssertEqual(store.allAttempts().count, 10, "two answered questions per subject")
        XCTAssertTrue(store.allAttempts().allSatisfy { $0.source == AttemptRecord.examSource })
        XCTAssertEqual(store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: day(2026, 10, 7, hour: 16)).answeredToday, 0)
        XCTAssertEqual(store.subjectExams(of: full).map(\.score), [2, 2, 2, 2, 2])
    }
}
