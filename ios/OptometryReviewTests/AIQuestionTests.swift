import XCTest
import SwiftData
@testable import OptometryReview

/// AI 出題 (docs/AI出題與圖解.md): 掌握度 weighting, AI 錯題, exclusion from review and stats, figures.
final class AIQuestionTests: XCTestCase {
    private let point = StudyPoint(id: "U#1", unitID: "U", number: 1, title: "t", summary: "")

    private func ai(_ n: Int) -> AIQuestion {
        AIQuestion(id: "ai:t:\(n)", unitID: "U", pointIDs: ["U#1"], answer: "B")
    }

    private func stat(official: [Bool], aiAnswers: [(Int, Bool)]) -> PointStat {
        let ids = ["a", "b", "c"]
        let attempts = official.enumerated().map { PointMastery.Attempt(questionID: ids[$0.offset % 3], correct: $0.element, unsure: false) }
        let facts = aiAnswers.enumerated().map {
            AIAttemptFact(questionID: "ai:t:\($0.element.0)", chosen: "A", correct: $0.element.1, unsure: false,
                          at: Date(timeIntervalSince1970: Double($0.offset)))
        }
        let bank = AIQuestionBank(questions: (1...6).map(ai), isSample: true)
        let input = AIPractice.pointInput(facts: facts, bank: bank)
        return PointMastery.compute(points: [point], scope: Set(ids), questionsOfPoint: ["U#1": ids],
                                    attempts: attempts, open: [], ai: input)["U#1"]!
    }

    // MARK: 掌握度 weighting

    func testAIAnswersCountAtHalfWeight() {
        // Three right 歷屆 answers on three questions are 穩定.
        XCTAssertEqual(stat(official: [true, true, true], aiAnswers: []).label, .steady)
        // One wrong AI answer weighs 0.5: below the 1.0 an open 歷屆 mistake needs to make it 還不穩.
        XCTAssertEqual(stat(official: [true, true, true], aiAnswers: [(1, false)]).label, .steady)
        // Two wrong AI answers add up to one open mistake.
        XCTAssertEqual(stat(official: [true, true, true], aiAnswers: [(1, false), (2, false)]).label, .shaky)
        // Four weigh as two open mistakes.
        XCTAssertEqual(stat(official: [true, true, true], aiAnswers: [(1, false), (2, false), (3, false), (4, false)]).label,
                       .needsWork)
        // The same four as official mistakes would be 待加強 already with two.
        XCTAssertEqual(stat(official: [true, true, true], aiAnswers: [(1, true), (2, true), (3, true)]).label, .steady)
    }

    func testAICountsStayApartFromOfficialNumbers() {
        let s = stat(official: [true, false, true], aiAnswers: [(1, false), (2, true), (2, true)])
        XCTAssertEqual([s.answers, s.wrong], [3, 1], "歷屆 numbers never include AI answers")
        XCTAssertEqual([s.ai.questions, s.ai.answers, s.ai.wrong, s.ai.done, s.ai.open], [6, 3, 1, 2, 1])
        XCTAssertEqual(s.countsText, "錯 1／做 3")
        XCTAssertEqual(s.ai.countsText, "錯 1／做 3")
    }

    func testOnlyAIAnswersStillMakeAPointTouched() {
        let s = stat(official: [], aiAnswers: [(1, true)])
        XCTAssertEqual(s.answers, 0)
        XCTAssertEqual(s.label, .shaky, "half a question done is under the three needed")
    }

    // MARK: AI 錯題

    func testAIMistakeMembershipFollowsTheLatestAnswer() {
        let bank = AIQuestionBank(questions: (1...3).map(ai), isSample: true)
        func fact(_ n: Int, _ correct: Bool, _ t: Double) -> AIAttemptFact {
            AIAttemptFact(questionID: "ai:t:\(n)", chosen: correct ? "B" : "A", correct: correct, unsure: false,
                          at: Date(timeIntervalSince1970: t))
        }
        let facts = [fact(1, false, 1), fact(2, false, 2), fact(2, true, 3), fact(3, true, 4), fact(3, false, 5)]
        let ids = AIPractice.mistakes(facts: facts, bank: bank).map(\.question.id)
        XCTAssertEqual(ids, ["ai:t:3", "ai:t:1"], "newest mistake first; 2 left after one correct answer")
        let tally = AIPractice.tally(for: bank.questions, facts: facts)
        XCTAssertEqual([tally.questions, tally.done, tally.wrong, tally.open], [3, 3, 3, 2])
        XCTAssertTrue(AIPractice.mistakes(facts: facts, bank: AIQuestionBank.empty).isEmpty)
    }

    func testPracticeOrderPutsNeverAnsweredFirstThenMistakes() {
        let qs = (1...4).map(ai)
        let facts = [AIAttemptFact(questionID: "ai:t:1", chosen: "B", correct: true, unsure: false, at: Date(timeIntervalSince1970: 1)),
                     AIAttemptFact(questionID: "ai:t:2", chosen: "A", correct: false, unsure: false, at: Date(timeIntervalSince1970: 2))]
        XCTAssertEqual(AIPractice.ordered(qs, facts: facts).map(\.id), ["ai:t:3", "ai:t:4", "ai:t:2", "ai:t:1"])
    }

    // MARK: Exclusion from review and statistics

    @MainActor
    func testAIAnswersAreKeptOutOfReviewAndStatistics() throws {
        let container = try ModelContainer(for: QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self,
                                           QuestionNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var events: [(String, [String: Any])] = []
        let store = StudyStore(context: container.mainContext, usageSink: { events.append(($0, $1)) })
        let q = ai(1)
        let now = Date()
        XCTAssertNotNil(store.commitAI(question: q, chosen: "A", unsure: false, now: now))
        XCTAssertNotNil(store.commitAI(question: q, chosen: "B", unsure: true, now: now.addingTimeInterval(5)))
        // Nothing official was created or counted.
        XCTAssertTrue(store.allRecords().isEmpty, "no QuestionRecord, no review card")
        XCTAssertTrue(store.allAttempts().isEmpty)
        XCTAssertTrue(store.attempts(since: now.addingTimeInterval(-60)).isEmpty)
        XCTAssertTrue(store.attemptFacts().isEmpty, "study log and weekly days ignore AI answers")
        let bank = QuestionBank(questions: [])
        let summary = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: now.addingTimeInterval(10))
        XCTAssertEqual(summary.correctToday, 0)
        XCTAssertEqual(summary.totalAttempts, 0)
        XCTAssertTrue(store.mistakeMarks(now: now.addingTimeInterval(10)).guessed.isEmpty)
        // They are stored as AttemptRecords with source "ai" and the ai: id.
        let stored = store.aiAttempts()
        XCTAssertEqual(stored.map(\.questionID), ["ai:t:1", "ai:t:1"])
        XCTAssertEqual(stored.map(\.correct), [false, true])
        XCTAssertEqual(stored.map(\.source), ["ai", "ai"])
        XCTAssertEqual(stored.map(\.unsure), [false, true])
        // Usage events carry source "ai".
        XCTAssertEqual(events.map(\.0), ["answer", "answer"])
        XCTAssertEqual(events.compactMap { $0.1["source"] as? String }, ["ai", "ai"])
        XCTAssertEqual(events.first?.1["chosen"] as? String, "A")
        XCTAssertEqual(UsageLog.answerSource("ai"), "ai")
        // 看解答 counts as a wrong answer without a chosen letter.
        store.commitAI(question: q, chosen: "", unsure: false, revealed: true, now: now.addingTimeInterval(9))
        XCTAssertEqual(AIPractice.mistakes(facts: store.aiFacts(), bank: AIQuestionBank(questions: [q], isSample: true)).count, 1)
        XCTAssertNil(events.last?.1["chosen"])
    }

    @MainActor
    func testAIBookmarkReusesQuestionNote() throws {
        let container = try ModelContainer(for: QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self,
                                           QuestionNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = StudyStore(context: container.mainContext, usageSink: { _, _ in })
        let q = ai(7)
        XCTAssertFalse(store.isAIBookmarked(q.id))
        store.setAIBookmark(true, question: q)
        XCTAssertTrue(store.isAIBookmarked(q.id))
        XCTAssertEqual(store.note(for: q.id)?.questionID, "ai:t:7")
        store.setAIBookmark(false, question: q)
        XCTAssertFalse(store.isAIBookmarked(q.id))
    }

    // MARK: Data file

    func testBankDecodesTheFormatAndDropsBrokenQuestions() throws {
        let json = """
        {"version":1,"sample":true,"questions":[
         {"id":"ai:t:1","templateId":"t","subject":"視覺光學","unitID":"U","pointIDs":["U#1"],"stem":"s",
          "options":{"A":"1","B":"2","C":"3","D":"4"},"answer":"B","wrongNotes":{"A":"x"},"steps":["a"],
          "figure":{"type":"prentice","params":{"power":-6,"decentrationMM":3,"direction":"up","eye":"OD"}},
          "sourceQuestionID":"106111_視覺光學_29","audit":{"model":"m","agreed":true,"at":"2026-10-10T00:00:00Z"}},
         {"id":"ai:t:2","subject":"視覺光學","unitID":"U","stem":"s","options":{"A":"1","B":"2"},"answer":"D"},
         {"id":"x:3","subject":"視覺光學","unitID":"U","stem":"s","options":{"A":"1","B":"2"},"answer":"A"}]}
        """.data(using: .utf8)!
        let bank = AIQuestionBank(json: json)
        XCTAssertTrue(bank.isSample)
        XCTAssertEqual(bank.questions.map(\.id), ["ai:t:1"], "answer outside the options and ids without the ai: prefix are dropped")
        XCTAssertEqual(bank.questions(unit: "U").count, 1)
        XCTAssertEqual(bank.questions(point: "U#1").count, 1)
        XCTAssertNotNil(AIFigure.make(try XCTUnwrap(bank.questions.first?.figure)))
    }

    func testBundledSampleIsConsistent() throws {
        let bank = QuestionBank.loadFromBundle(Bundle(for: QuestionBank.self))
        // The test host is the app, so the bundled file is available.
        let ai = bank.ai
        XCTAssertFalse(ai.questions.isEmpty)
        for q in ai.questions {
            XCTAssertEqual(Set(q.options.keys), ["A", "B", "C", "D"], q.id)
            XCTAssertEqual(Set(q.wrongNotes.keys), Set(q.options.keys).subtracting([q.answer]), q.id)
            XCTAssertNotNil(bank.unitByID[q.unitID], q.id)
            XCTAssertTrue(q.pointIDs.allSatisfy { bank.learning.pointByID[$0] != nil }, q.id)
            if let src = q.sourceQuestionID { XCTAssertNotNil(bank.byID[src], q.id) }
            // A figure that cannot be checked against the steps is hidden on purpose. Known gaps of the generator's
            // data: hyperopic near/far points (not drawn) and Sturm questions with a nearby point source (the figure shows
            // parallel light), so only these two templates may go without a figure.
            if q.figure != nil, AIFigure.checked(q.figure, steps: q.steps, answerText: q.answerText) == nil {
                XCTAssertTrue(["accom-amplitude", "sturm-interval", "sturm-lcc"].contains(q.templateId), "\(q.id) figure must verify")
            }
        }
    }

    // MARK: Figures

    private func spec(_ type: String, _ p: [String: AIParam]) -> AIFigureSpec { AIFigureSpec(type: type, params: p) }

    func testPrenticeRecomputesPrismAndBase() throws {
        let f = try XCTUnwrap(AIFigure.make(spec("prentice", ["power": .number(-10), "decentrationMM": .number(2),
                                                              "direction": .text("down"), "eye": .text("OD")])))
        guard case .prentice(let p) = f else { return XCTFail() }
        XCTAssertEqual(p.prism, 2.0, accuracy: 1e-9)
        XCTAssertEqual(p.base, .up, "minus lens: base away from the centre, which sits below the axis")
        XCTAssertTrue(f.verify(steps: ["P = 0.2 × 10.00 = 2.00Δ"]))
        XCTAssertFalse(f.verify(steps: ["P = 0.2 × 10.00 = 4.00Δ"]), "a figure that disagrees with the steps is not drawn")
    }

    func testFigureValuesMatchTheWorkedSolutions() throws {
        func make(_ t: String, _ p: [String: AIParam]) throws -> AIFigure { try XCTUnwrap(AIFigure.make(spec(t, p))) }
        guard case .vertex(let v) = try make("vertex", ["power": .number(-8), "fromMM": .number(12), "toMM": .number(0)]) else { return XCTFail() }
        XCTAssertEqual(v.converted, -7.299, accuracy: 0.001)
        XCTAssertEqual(v.convertedRounded, -7.25)
        XCTAssertEqual(v.focusToNewPlaneCM, -13.7, accuracy: 0.01)
        guard case .thinLens(let l) = try make("thinLens", ["power": .number(5), "objectCM": .number(30)]) else { return XCTFail() }
        XCTAssertEqual(l.imageCM, 60, accuracy: 1e-9)
        XCTAssertEqual(l.magnification, -2, accuracy: 1e-9)
        XCTAssertTrue(l.isReal)
        guard case .sturm(let s) = try make("sturm", ["sphere": .number(4), "cyl": .number(1), "axis": .number(180)]) else { return XCTFail() }
        XCTAssertEqual(s.strongDistanceCM, 20, accuracy: 1e-9)
        XCTAssertEqual(s.weakDistanceCM, 25, accuracy: 1e-9)
        XCTAssertEqual(s.circleDistanceCM, 22.22, accuracy: 0.01)
        XCTAssertEqual(s.strongMeridian, 90, "axis 180: the vertical meridian is the strong one")
        guard case .nearFar(let n) = try make("nearFar", ["refraction": .number(-2), "amplitude": .number(6)]) else { return XCTFail() }
        XCTAssertEqual([n.farCM, n.nearCM, n.correctedNearCM].map { ($0 * 10).rounded() / 10 }, [50, 12.5, 16.7])
        guard case .tabo(let t) = try make("tabo", ["eye": .text("OD"), "sphere": .number(-2), "cyl": .number(-1.25), "axis": .number(30)]) else { return XCTFail() }
        XCTAssertEqual(t.crossPower, -3.25)
        XCTAssertEqual(t.crossMeridian, 120)
    }

    func testUnusableParametersGiveNoFigure() {
        XCTAssertNil(AIFigure.make(spec("prentice", ["power": .number(0), "decentrationMM": .number(2), "direction": .text("up"), "eye": .text("OD")])))
        XCTAssertNil(AIFigure.make(spec("prentice", ["power": .number(2), "decentrationMM": .number(2), "direction": .text("left"), "eye": .text("OD")])))
        XCTAssertNil(AIFigure.make(spec("thinLens", ["power": .number(5), "objectCM": .number(20)])), "object at the focal point has no image")
        XCTAssertNil(AIFigure.make(spec("sturm", ["sphere": .number(-1), "cyl": .number(1), "axis": .number(90)])))
        XCTAssertNil(AIFigure.make(spec("nearFar", ["refraction": .number(2), "amplitude": .number(3)])), "hyperopia is not drawn")
        XCTAssertNil(AIFigure.make(spec("unknown", [:])))
        XCTAssertNil(AIFigure.checked(spec("sturm", ["sphere": .number(4), "cyl": .number(1), "axis": .number(180)]),
                                      steps: ["最小模糊圈：30 cm"]))
    }

    func testConceptFiguresNeedOnlyValidParameters() {
        XCTAssertNotNil(AIFigure.checked(spec("eom", ["eye": .text("OS"), "muscle": .text("SO")]), steps: []))
        XCTAssertNotNil(AIFigure.checked(spec("visualField", ["lesion": .text("chiasm"), "side": .text("L")]), steps: []))
        XCTAssertNil(AIFigure.make(spec("eom", ["eye": .text("OD"), "muscle": .text("XX")])))
    }

    // MARK: Reports

    func testFigureReportCarriesTypeParamsAndReasonButNoAnswer() {
        let q = AIQuestion(id: "ai:t:1", unitID: "U", figure: spec("prentice", ["power": .number(-6), "direction": .text("up")]))
        let fields = AIReport.figureFields(question: q, reason: .direction, note: " 方向不對 ")
        XCTAssertEqual(fields["qid"] as? String, "ai:t:1")
        XCTAssertEqual(fields["category"] as? String, "figure")
        XCTAssertEqual(fields["figureType"] as? String, "prentice")
        XCTAssertEqual(fields["figureReason"] as? String, "direction")
        XCTAssertEqual(fields["note"] as? String, "方向不對")
        XCTAssertNil(fields["chosen"])
        XCTAssertEqual(AIReport.questionFields(question: q, category: .answer, note: "")["source"] as? String, "ai")
    }

    // MARK: Saved notes

    @MainActor
    func testSavingTheSameNoteTwiceKeepsOne() throws {
        let container = try ModelContainer(for: SavedNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let bank = QuestionBank(questions: [])
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let note = InsightNote(misconception: "m", fix: "- f", at: at)
        let a = SavedNotes.save(context: context, bank: bank, pointID: "U#1", note: note, source: SavedNotes.nightly, questionIDs: ["q"])
        let b = SavedNotes.save(context: context, bank: bank, pointID: "U#1", note: note, source: SavedNotes.nightly, questionIDs: ["q"])
        XCTAssertEqual(a.noteID, b.noteID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedNote>()).count, 1)
        XCTAssertTrue(SavedNotes.isSaved(context: context, pointID: "U#1", note: note))
        let newer = InsightNote(misconception: "m2", fix: "- f", at: at.addingTimeInterval(86_400))
        XCTAssertFalse(SavedNotes.isSaved(context: context, pointID: "U#1", note: newer))
        SavedNotes.save(context: context, bank: bank, pointID: "U#1", note: newer, source: SavedNotes.review, questionIDs: [])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavedNote>()).count, 2)
    }
}
