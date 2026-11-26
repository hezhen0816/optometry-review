import Foundation
import SwiftData

/// One AI answer as the lists and the 掌握度 see it.
struct AIAttemptFact: Equatable {
    let questionID: String
    let chosen: String
    let correct: Bool
    let unsure: Bool
    let at: Date
}

/// An AI question whose latest answer is wrong.
struct AIMistake: Identifiable, Equatable {
    let question: AIQuestion
    /// The wrong letter chosen; empty after 「看解答」.
    let chosen: String
    let at: Date
    var id: String { question.id }
}

enum AIPractice {
    /// AI 錯題: a question is in the list while its latest answer is wrong; one correct answer removes it.
    /// Newest mistake first. Answers of questions missing from the bank are ignored.
    static func mistakes(facts: [AIAttemptFact], bank: AIQuestionBank) -> [AIMistake] {
        var latest: [String: AIAttemptFact] = [:]
        for f in facts.sorted(by: { $0.at < $1.at }) { latest[f.questionID] = f }
        return latest.values
            .filter { !$0.correct }
            .compactMap { f in bank.byID[f.questionID].map { AIMistake(question: $0, chosen: f.chosen, at: f.at) } }
            .sorted { $0.at > $1.at }
    }

    /// Per-unit tallies for the unit page and the unit overview.
    struct Tally: Equatable {
        var questions = 0
        var done = 0
        var wrong = 0
        /// Questions whose latest answer is wrong.
        var open = 0
    }

    static func tally(for questions: [AIQuestion], facts: [AIAttemptFact]) -> Tally {
        let ids = Set(questions.map(\.id))
        var latest: [String: AIAttemptFact] = [:]
        var wrong = 0
        for f in facts.sorted(by: { $0.at < $1.at }) where ids.contains(f.questionID) {
            latest[f.questionID] = f
            if !f.correct { wrong += 1 }
        }
        return Tally(questions: questions.count, done: latest.count, wrong: wrong,
                     open: latest.values.filter { !$0.correct }.count)
    }

    /// The mastery label wording for an AI question's point (for 「考點掌握度：待加強」 after an answer).
    static func pointInput(facts: [AIAttemptFact], bank: AIQuestionBank) -> PointMastery.AIInput {
        var pointsOfQuestion: [String: [String]] = [:]
        for q in bank.questions { pointsOfQuestion[q.id] = q.pointIDs }
        var questionsOfPoint: [String: [String]] = [:]
        for q in bank.questions { for p in q.pointIDs { questionsOfPoint[p, default: []].append(q.id) } }
        let attempts = facts.sorted { $0.at < $1.at }.map {
            PointMastery.Attempt(questionID: $0.questionID, correct: $0.correct, unsure: $0.unsure, at: $0.at)
        }
        return PointMastery.AIInput(attempts: attempts, pointsOfQuestion: pointsOfQuestion, questionsOfPoint: questionsOfPoint)
    }

    /// Practice order: questions never answered first, then those whose latest answer is wrong, then the rest,
    /// the longest-ago answered first; ties keep the file order so a round is stable.
    static func ordered(_ questions: [AIQuestion], facts: [AIAttemptFact]) -> [AIQuestion] {
        var latest: [String: AIAttemptFact] = [:]
        for f in facts.sorted(by: { $0.at < $1.at }) { latest[f.questionID] = f }
        func rank(_ q: AIQuestion) -> (Int, Date) {
            guard let f = latest[q.id] else { return (0, .distantPast) }
            return (f.correct ? 2 : 1, f.at)
        }
        return questions.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra.0 != rb.0 { return ra.0 < rb.0 }
            if ra.1 != rb.1 { return ra.1 < rb.1 }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// A question's figure is hidden on this device after 「圖有誤」 (the report itself goes out through the usage log).
    static let hiddenFiguresKey = "aiHiddenFigureQuestionIDs"

    static func hiddenFigureIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenFiguresKey) ?? [])
    }

    static func hideFigure(_ id: String, defaults: UserDefaults = .standard) {
        var ids = hiddenFigureIDs(defaults: defaults)
        ids.insert(id)
        defaults.set(Array(ids).sorted(), forKey: hiddenFiguresKey)
    }

    /// AI questions reported 「題目有誤」 on this device.
    static let reportedKey = QuestionReport.reportedKey
}

extension StudyStore {
    func isAIBookmarked(_ id: String) -> Bool { note(for: id)?.bookmarked ?? false }

    /// ☆ on an AI question: the same QuestionNote as official questions, keyed by the `ai:` id.
    func setAIBookmark(_ on: Bool, question q: AIQuestion, now: Date = .now) {
        let n: QuestionNote
        if let existing = note(for: q.id) { n = existing } else {
            n = QuestionNote(questionID: q.id, subject: q.subject, now: now)
            context.insert(n)
        }
        n.bookmarked = on
        n.updatedAt = now
        try? context.save()
    }

    /// Every AI answer, oldest first. They are kept out of `allAttempts()` so no review, stat or exam sees them.
    func aiAttempts() -> [AttemptRecord] {
        let all = (try? context.fetch(FetchDescriptor<AttemptRecord>())) ?? []
        return all.filter(\.isAI).sorted { ($0.timestamp, $0.answerOrder) < ($1.timestamp, $1.answerOrder) }
    }

    func aiFacts() -> [AIAttemptFact] {
        aiAttempts().map {
            AIAttemptFact(questionID: $0.questionID, chosen: $0.chosen, correct: $0.correct, unsure: $0.unsure, at: $0.timestamp)
        }
    }

    /// Saves one AI answer. No QuestionRecord and no schedule: AI questions never enter review.
    @discardableResult
    func commitAI(question: AIQuestion, chosen: String, unsure: Bool, revealed: Bool = false, now: Date = .now) -> AttemptRecord? {
        let now = now.wholeMillisecond   // CloudKit keeps milliseconds; `AttemptRecord.init` assigns a fresh attemptID
        let correct = !revealed && question.isCorrect(chosen)
        let attempt = AttemptRecord(questionID: question.id, subject: question.subject, timestamp: now,
                                    chosen: revealed ? "" : chosen, correct: correct, reason: nil,
                                    unsure: correct && unsure, source: AttemptRecord.aiSource)
        context.insert(attempt)
        do {
            try context.save()
        } catch {
            SaveFailureNotice.shared.report()
            return nil
        }
        var fields: [String: Any] = ["qid": question.id, "subject": question.subject,
                                     "source": AttemptRecord.aiSource, "correct": correct, "unsure": attempt.unsure]
        if revealed { fields["revealed"] = true }
        if !revealed, Question.letters.contains(chosen) { fields["chosen"] = chosen }
        usageSink("answer", fields)
        return attempt
    }
}
