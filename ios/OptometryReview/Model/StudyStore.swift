import Foundation
import SwiftData
import Observation

/// AppStorage keys shared across views.
enum SettingsKey {
    static let onboarded = "onboarded"
    /// Exam date as timeIntervalSince1970; 0 = not set.
    static let examDate = "examDate"
    static let dailyGoal = "dailyGoal"
    static let newRatioMode = "newRatioMode"
    static let customNewPercent = "customNewPercent"
    static let defaultNewRatioMode = NewRatioMode.normal.rawValue
    static let defaultCustomNewPercent = 25
    static let customNewPercentRange = 0...100
    static let customNewPercentStep = 5
    static let includeSpecial = "includeSpecial"
    /// 設定「題目頁預設遮住答案」: every detail question opens hidden; absent means off.
    /// New key on purpose: the retired "detailShowsAnswer" (top-bar 答案 toggle) is ignored, so everyone starts off.
    static let detailHidesAnswer = "detailHidesAnswer"
    /// Retired 設定「年份」 range; read once by `ScopeStore.migrateLegacyYears`.
    static let yearFrom = "yearFrom"
    static let yearTo = "yearTo"
    static let reminderEnabled = "reminderEnabled"
    static let usageLogEnabled = "usageLogEnabled"
    /// Vibration feedback; absent means on.
    static let hapticsEnabled = "hapticsEnabled"
    static let deviceName = "deviceName"
    /// Minutes after local midnight.
    static let reminderMinutes = "reminderMinutes"
    static let defaultReminderMinutes = 21 * 60
    static let tipReasonShown = "tip.reason.shown"
    static let tipExamGridShown = "tip.examGrid.shown"
    static let tipUnsureShown = "tip.unsure.shown"
    /// 0.3.0 first-visit tips (the retired "tip.unitSwitch.shown" is no longer read).
    /// 單元 tab: the counts on the first subject. 重點講義: the first 考點. AI 題: the 「AI 出題，非官方」 label.
    /// 錯題本: the 歷屆｜AI 錯題 switch. 模擬考: 歷屆試卷.
    static let tipUnitsShown = "tip.units.shown"
    static let tipHandoutShown = "tip.handout.shown"
    static let tipAIQuestionShown = "tip.aiQuestion.shown"
    static let tipAIMistakesShown = "tip.aiMistakes.shown"
    static let tipPapersShown = "tip.papers.shown"
    /// One-line explanations shown only the first time (not coach marks): abandoning a 五科連考, a question moved to 不用再練.
    static let noteAbandonShown = "note.abandonFull.shown"
    static let noteRetiredShown = "note.retired.shown"

    /// Every coach mark. The flags sync between devices (`SettingsSync`) and 設定's reset clears them everywhere.
    static let allTips = [tipReasonShown, tipExamGridShown, tipUnsureShown,
                          tipUnitsShown, tipHandoutShown, tipAIQuestionShown, tipAIMistakesShown, tipPapersShown,
                          noteAbandonShown, noteRetiredShown]

    /// A coach mark shows once: until its key is set (also by `-tipsShown` and cleared by 設定's reset).
    static func tipPending(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key)
    }

    static func markTipShown(_ key: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// Exam date from settings (start of day), or nil.
    static var examDateValue: Date? {
        let t = UserDefaults.standard.double(forKey: examDate)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static let defaultDailyGoal = 20
    static let dailyGoalRange = 5...100
    static let dailyGoalStep = 5

    /// A stored 每日題數 forced into `dailyGoalRange`: missing or non-integer values become the default, out-of-range
    /// integers the nearest bound (a stray 4 from an old build or a sync must not reach the screens).
    static func sanitizedDailyGoal(_ stored: Any?) -> Int {
        guard let n = (stored as? NSNumber)?.intValue else { return defaultDailyGoal }
        return min(max(n, dailyGoalRange.lowerBound), dailyGoalRange.upperBound)
    }

    /// Rewrites an out-of-range stored 每日題數 in place (launch, before the views and iCloud sync read it).
    static func repairDailyGoal(defaults: UserDefaults = .standard) {
        guard let stored = defaults.object(forKey: dailyGoal) else { return }
        let fixed = sanitizedDailyGoal(stored)
        if (stored as? NSNumber)?.intValue != fixed { defaults.set(fixed, forKey: dailyGoal) }
    }
}

/// Summary for the 今日 screen.
struct TodaySummary {
    var answeredToday: Int
    var plan: DailyPlanner.Plan
    /// Today's review items (due reviews plus 再次挑戰 retries) per subject; sums to `reviewCount`.
    var reviewBySubject: [String: Int]
    var totalAttempts: Int
    /// Questions in the active pool attempted at least once, and the pool size.
    var seenInPool: Int = 0
    var poolSize: Int = 0
    var newAnsweredToday: Int = 0
    var correctToday: Int = 0
    var retryIDs: [String] = []
    var todayStudy: StudyTime.Day? = nil
    /// 五科進度 under the 練習範圍, official subject order.
    var subjectProgress: [SubjectProgress] = []

    var dueCount: Int { plan.dueIDs.count }
    var retryCount: Int { retryIDs.count }
    /// Everything the 今日 card counts as 待複習 or 再次挑戰 (each question once).
    var reviewCount: Int { plan.reviewIDs.count }
    var studyMinutesToday: Double { todayStudy?.minutes ?? 0 }
    var answeredCountToday: Int { todayStudy?.answeredCount ?? 0 }
    var reviewAnsweredToday: Int { todayStudy?.reviewAnsweredCount ?? 0 }
    var todayAccuracy: Int? { todayStudy?.accuracy }
    func goalMet(_ goal: Int) -> Bool { correctToday >= goal }

    static func countBySubject(_ ids: [String], subject: (String) -> String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for id in ids {
            if let s = subject(id) { counts[s, default: 0] += 1 }
        }
        return counts
    }
}

/// An answer could not be saved; the root view shows an alert once per failure burst.
@MainActor @Observable
final class SaveFailureNotice {
    static let shared = SaveFailureNotice()
    var visible = false
    private(set) var count = 0

    func report() {
        count += 1
        visible = true
    }
}

/// SwiftData-backed operations. Scheduling rules live in `Scheduler` / `DailyPlanner`.
@MainActor
struct StudyStore {
    let context: ModelContext
    var scheduler = Scheduler(examDate: SettingsKey.examDateValue)
    var defaults: UserDefaults = .standard
    var usageSink: UsageLog.Sink = { UsageLog.shared.log($0, $1) }
    var preExamPlanDidBuild: () -> Void = {}

    private func preExamPlan(at now: Date) -> [String: ReviewDue] {
        PreExamReviewPlanner.cachedPlan(context: context, scheduler: scheduler, now: now,
                                       onBuild: preExamPlanDidBuild)
    }

    /// One option tap, with a stable timestamp and scheduler baseline for later sheet edits.
    @MainActor final class PendingAnswer {
        let timestamp: Date
        let before: ReviewSchedule
        let lastAnswered: Date?
        let reviewDue: ReviewDue?
        fileprivate var attempt: AttemptRecord?

        init(timestamp: Date, record: QuestionRecord?, reviewDue: ReviewDue?) {
            self.timestamp = timestamp
            before = record?.schedule ?? .unseen
            lastAnswered = record?.lastAnswered
            self.reviewDue = reviewDue
        }
    }

    func pendingAnswer(for questionID: String, now: Date = .now) -> PendingAnswer {
        let record = record(for: questionID)
        return PendingAnswer(timestamp: now.wholeMillisecond, record: record,
                             reviewDue: record?.resumeReviewDue ?? preExamPlan(at: now)[questionID])
    }

    func allRecords() -> [QuestionRecord] {
        (try? context.fetch(FetchDescriptor<QuestionRecord>())) ?? []
    }

    func record(for id: String) -> QuestionRecord? {
        let d = FetchDescriptor<QuestionRecord>(predicate: #Predicate { $0.questionID == id })
        return (try? context.fetch(d))?.sorted(by: StudyDeduplication.recordOrder).first
    }

    /// Official answers only: AI answers (`source == "ai"`) never reach review, stats, exams or the study log.
    func attempts(since date: Date) -> [AttemptRecord] {
        let d = FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.timestamp >= date })
        return ((try? context.fetch(d)) ?? []).filter { !$0.isAI }
    }

    /// Official answers only (see `attempts(since:)`); AI answers come from `aiAttempts()`.
    func allAttempts() -> [AttemptRecord] {
        ((try? context.fetch(FetchDescriptor<AttemptRecord>())) ?? []).filter { !$0.isAI }
    }

    /// Schedule that would result from an answer, without saving.
    func preview(questionID: String, correct: Bool, unsure: Bool, retry: Bool = false, now: Date = .now) -> ReviewStatus {
        let rec = record(for: questionID)
        if let rec, rec.parked { return rec.reviewStatus(using: scheduler, at: now) }
        let due = rec?.resumeReviewDue ?? preExamPlan(at: now)[questionID]
        return scheduler.preview(rec?.schedule ?? .unseen, outcome: ReviewOutcome(correct: correct, unsure: unsure, retry: retry),
                                 at: now, reviewDue: due)
    }

    /// Persists one answer and returns the new schedule.
    @discardableResult
    func commit(question: Question, chosen: String, correct: Bool, unsure: Bool, reason: String?,
                confident: Bool = false, revealed: Bool = false, source: String? = nil, seconds: Double? = nil,
                usageSource: String? = nil, pending: PendingAnswer? = nil,
                precomputedPlan: [String: ReviewDue]? = nil, retry: Bool = false, now: Date = .now) -> ReviewSchedule {
        let now = pending?.timestamp ?? now.wholeMillisecond
        let rec: QuestionRecord
        if let existing = record(for: question.id) {
            rec = existing
        } else {
            rec = QuestionRecord(questionID: question.id, subject: question.subject, now: now)
            context.insert(rec)
        }
        let reviewDue = pending == nil ? (rec.resumeReviewDue ?? (precomputedPlan ?? preExamPlan(at: now))[question.id]) : pending?.reviewDue
        let before = pending?.before ?? rec.schedule
        let lastAnswered = pending == nil ? rec.lastAnswered : pending?.lastAnswered
        // Correct retry answers finish the local challenge even if marked unsure; tomorrow's FSRS stays intact.
        let isRetry = retry || (pending?.attempt?.retry ?? false)
        let outcome = ReviewOutcome(correct: correct, unsure: unsure, retry: isRetry)
        let outOfOrder = rec.lastReview.map { now < $0 } ?? false
        let earlyCorrect = scheduler.isEarlyCorrect(before, outcome: outcome, at: now, reviewDue: reviewDue)
        let after = outOfOrder ? rec.schedule : scheduler.next(before, outcome: outcome, at: now, reviewDue: reviewDue)
        rec.schedule = after
        if !outOfOrder && !earlyCorrect { rec.resumeDueDate = nil }
        if !outOfOrder { rec.fsrsVersion = StudyReplay.version }
        // Early practice is recorded in attempts but must not move the exam-policy anchor.
        rec.lastAnswered = max(rec.lastAnswered, outOfOrder || !earlyCorrect ? now : (lastAnswered ?? now))
        if !correct && !outOfOrder {
            rec.lastReason = reason
            rec.lastConfident = confident
        }
        let isNew = pending?.attempt == nil
        let attempt: AttemptRecord
        if let existing = pending?.attempt {
            attempt = existing
            attempt.chosen = chosen
            attempt.correct = correct
            attempt.reason = correct ? nil : reason
            attempt.unsure = unsure
        } else {
            attempt = AttemptRecord(questionID: question.id, subject: question.subject, timestamp: now,
                                    chosen: chosen, correct: correct, reason: correct ? nil : reason,
                                    unsure: unsure, source: source)
            attempt.answerOrder = (rec.attempts ?? []).map(\.answerOrder).max().map { $0 + 1 } ?? 1
            context.insert(attempt)
            pending?.attempt = attempt
        }
        attempt.confident = !correct && confident
        attempt.retry = isRetry
        attempt.masteredBefore = outOfOrder ? nil : (!rec.parked && scheduler.isMastered(before, at: now))
        attempt.record = rec
        PreExamReviewPlanner.invalidate(context: context)
        do {
            try context.save()
            guard isNew else { return after }
            let status = rec.reviewStatus(using: scheduler, at: now, reviewDue: rec.resumeReviewDue)
            var fields: [String: Any] = ["qid": attempt.questionID, "subject": attempt.subject,
                "source": UsageLog.answerSource(usageSource ?? attempt.source ?? UsageLog.shared.answerSource),
                "correct": attempt.correct, "unsure": attempt.unsure,
                "confident": attempt.confident, "reason": attempt.reason as Any? ?? NSNull(),
                "intervalDays": status.daysUntilNextReview.map { max(0, $0) } as Any? ?? NSNull(),
                "stability": (status.stabilityDays * 100).rounded() / 100,
                "mastered": status.mastered]
            if let seconds { fields["seconds"] = seconds }
            // 「看解答」: counted as a wrong answer without picking an option.
            if revealed && !correct { fields["revealed"] = true }
            // The option she picked, as the ORIGINAL letter (never the shuffled on-screen one); absent for 「看解答」.
            if !revealed, Question.letters.contains(attempt.chosen) { fields["chosen"] = attempt.chosen }
            if isRetry { fields["retry"] = true }
            usageSink("answer", fields)
        } catch {
            SaveFailureNotice.shared.report()
        }
        return after
    }

    func todaySummary(bank: QuestionBank, includeSpecial: Bool, goal: Int, now: Date = .now) -> TodaySummary {
        let cal = scheduler.calendar
        let startOfDay = cal.startOfDay(for: now)
        let records = allRecords()
        let attempts = allAttempts()
        let facts = attemptFacts(from: attempts)
        // Mock exam answers schedule mistakes but do not count toward the daily goal.
        let answeredToday = Set(attempts.filter { $0.timestamp >= startOfDay && $0.timestamp <= now && $0.source != AttemptRecord.examSource }
            .map(\.questionID)).count
        let correctToday = WeeklyGoal.goalCounts(facts.filter { $0.timestamp <= now }, calendar: cal)[startOfDay] ?? 0
        let firstAttempts = Dictionary(grouping: attempts, by: \.questionID).compactMapValues { list in
            list.map(\.timestamp).min()
        }
        let newAnsweredToday = firstAttempts.values.filter { $0 >= startOfDay && $0 <= now }.count
        let preExam = PreExamReviewPlanner.plan(records: records, scheduler: scheduler, now: now)
        let parked = Set(records.filter(\.parked).map(\.questionID))
        let activePool = Set(bank.reviewPool(includeSpecial: includeSpecial).map(\.id))
        let retryIDs = RetryQueue.rebuild(attempts: facts, now: now, calendar: cal, excluding: parked)
            .filter { activePool.contains($0) }

        var due: [DailyPlanner.DueItem] = []
        for r in records where !r.parked && scheduler.isDue(r.schedule, on: now,
                                                          reviewDue: r.resumeReviewDue ?? preExam[r.questionID]) {
            // Due items must still be in the active pool (e.g. 特考 off hides 特考 mistakes).
            guard let q = bank.byID[r.questionID],
                  q.examKind == ExamKind.general || includeSpecial else { continue }
            let effective = scheduler.effectiveDue(r.schedule, now: now, reviewDue: r.resumeReviewDue ?? preExam[r.questionID])
            due.append(.init(id: r.questionID, due: effective ?? startOfDay, subject: q.subject,
                             isConfirmation: r.schedule.isConfirmation))
        }
        let confirmationsReviewedToday = Self.confirmationsReviewed(attempts: attempts, records: records,
                                                                    since: startOfDay, now: now)
        let confirmationLimit = DailyPlanner.confirmationLimit(goal: goal, reviewedToday: confirmationsReviewedToday,
                                                               examDate: scheduler.examDate, now: now, calendar: cal)

        var accuracy: [String: DailyPlanner.SubjectAccuracy] = [:]
        for a in attempts {
            accuracy[a.subject, default: .init(correct: 0, total: 0)].total += 1
            if a.correct { accuracy[a.subject]!.correct += 1 }
        }

        let seen = Set(records.map(\.questionID))
        let (poolCount, unseen) = dayOrderedUnseen(bank: bank, includeSpecial: includeSpecial, seen: seen, now: now)
        let progress = SubjectProgress.compute(pool: bank.newQuestionPool(includeSpecial: includeSpecial, defaults: defaults),
                                               answeredIDs: seen)
        var unseenBySubject: [String: [String]] = [:]
        for q in unseen { unseenBySubject[q.subject, default: []].append(q.id) }

        let plan = DailyPlanner.plan(due: due, unseenBySubject: unseenBySubject, accuracy: accuracy,
                                     goal: goal, answeredToday: answeredToday, newAnsweredToday: newAnsweredToday,
                                     correctToday: correctToday, retryIDs: retryIDs, ratioMode: NewRatioMode.value(defaults),
                                     customNewPercent: NewRatioMode.customPercent(defaults),
                                     confirmationLimit: confirmationLimit,
                                     answeredBySubject: SubjectProgress.answeredBySubject(progress))
        // Retries (wrong earlier today, including mock exams) are listed with the due reviews.
        let reviewBySubject = TodaySummary.countBySubject(plan.reviewIDs) { bank.byID[$0]?.subject }
        return TodaySummary(answeredToday: answeredToday, plan: plan, reviewBySubject: reviewBySubject,
                            totalAttempts: attempts.count, seenInPool: poolCount - unseen.count, poolSize: poolCount,
                            newAnsweredToday: newAnsweredToday, correctToday: correctToday, retryIDs: retryIDs,
                            todayStudy: studyActivity(attempts: facts, now: now).today, subjectProgress: progress)
    }

    /// 確認題 reviewed today, whatever the outcome: cards answered only plainly correct before today and answered today
    /// either wrong or 猜的 (now mistakes) or as a due review (their FSRS state moved today). An early correct answer
    /// changes nothing and does not count.
    static func confirmationsReviewed(attempts: [AttemptRecord], records: [QuestionRecord], since startOfDay: Date,
                                      now: Date) -> Int {
        func plainCorrect(_ a: AttemptRecord) -> Bool { a.correct && (!a.unsure || a.retry) }
        var lastReview: [String: Date] = [:]
        for r in records { if let d = r.lastReview { lastReview[r.questionID] = max(lastReview[r.questionID] ?? d, d) } }
        var count = 0
        for (id, list) in Dictionary(grouping: attempts.filter { $0.timestamp <= now }, by: \.questionID) {
            let before = list.filter { $0.timestamp < startOfDay }
            let today = list.filter { $0.timestamp >= startOfDay }
            guard !before.isEmpty, !today.isEmpty, before.allSatisfy(plainCorrect) else { continue }
            if today.contains(where: { !plainCorrect($0) }) || (lastReview[id] ?? .distantPast) >= startOfDay {
                count += 1
            }
        }
        return count
    }

    /// Unseen questions of the new-question pool in today's stable order (shared by the planner and extra sessions).
    private func dayOrderedUnseen(bank: QuestionBank, includeSpecial: Bool, seen: Set<String>,
                                  now: Date) -> (poolCount: Int, unseen: [Question]) {
        let startOfDay = scheduler.calendar.startOfDay(for: now)
        let dayNumber = UInt64(max(0, Int(startOfDay.timeIntervalSince1970 / 86_400)))
        var rng = SeededGenerator(seed: dayNumber)
        let pool = bank.newQuestionPool(includeSpecial: includeSpecial, defaults: defaults)
        return (pool.count, pool.filter { !seen.contains($0.id) }.shuffled(using: &rng))
    }

    /// Extra new questions after the daily goal is done.
    func extraNewQuestions(bank: QuestionBank, includeSpecial: Bool, count: Int, now: Date = .now) -> [String] {
        let seen = Set(allRecords().map(\.questionID))
        let (_, unseen) = dayOrderedUnseen(bank: bank, includeSpecial: includeSpecial, seen: seen, now: now)
        let progress = SubjectProgress.compute(pool: bank.newQuestionPool(includeSpecial: includeSpecial, defaults: defaults),
                                               answeredIDs: seen)
        let groups = Dictionary(grouping: unseen, by: \.subject).mapValues { $0.map(\.id) }
        var accuracy: [String: DailyPlanner.SubjectAccuracy] = [:]
        for a in allAttempts() {
            accuracy[a.subject, default: .init(correct: 0, total: 0)].total += 1
            if a.correct { accuracy[a.subject]!.correct += 1 }
        }
        return DailyPlanner.pickNew(count: max(0, count), unseenBySubject: groups, accuracy: accuracy,
                                    answeredBySubject: SubjectProgress.answeredBySubject(progress))
    }

    /// 「練這科」 queue size: due reviews first, then new questions up to this many in total.
    static let subjectSessionSize = 10

    /// One subject's session: its due reviews and 再次挑戰 from today's plan (retries first), then new questions of the
    /// 練習範圍 in today's stable order, `subjectSessionSize` in total. Empty when the subject has nothing due and no
    /// new question left in the scope.
    func subjectQueue(subject: String, summary: TodaySummary, bank: QuestionBank, includeSpecial: Bool,
                      now: Date = .now) -> (queue: [String], retryIDs: Set<String>) {
        let reviews = summary.plan.reviewIDs.filter { bank.byID[$0]?.subject == subject }
        var queue = Array(reviews.prefix(Self.subjectSessionSize))
        if queue.count < Self.subjectSessionSize {
            let (_, unseen) = dayOrderedUnseen(bank: bank, includeSpecial: includeSpecial,
                                              seen: Set(allRecords().map(\.questionID)), now: now)
            queue += unseen.filter { $0.subject == subject }.prefix(Self.subjectSessionSize - queue.count).map(\.id)
        }
        return (queue, Set(summary.retryIDs).intersection(queue))
    }

    // MARK: Parked questions

    @discardableResult
    func park(questionID: String, now: Date = .now) -> Bool {
        guard let r = record(for: questionID) else { return false }
        guard !r.parked else { return true }
        let previous = (r.parkedAt, r.resumeDueDate)
        r.parked = true
        r.parkedAt = now.wholeMillisecond
        r.resumeDueDate = nil
        PreExamReviewPlanner.invalidate(context: context)
        do {
            try context.save()
            usageSink("park", ["qid": questionID])
            return true
        } catch {
            r.parked = false
            r.parkedAt = previous.0
            r.resumeDueDate = previous.1
            return false
        }
    }

    @discardableResult
    func unpark(questionID: String, now: Date = .now) -> Bool {
        guard let r = record(for: questionID) else { return false }
        guard r.parked else { return true }
        let previous = (r.parkedAt, r.dueDate, r.resumeDueDate)
        r.parked = false
        // Keeps the time of this change so an iCloud merge can tell it is newer than a park on another device.
        r.parkedAt = now.wholeMillisecond
        if r.schedule.isScheduled {
            let tomorrow = scheduler.addDays(1, to: scheduler.calendar.startOfDay(for: now))
            r.dueDate = tomorrow
            r.resumeDueDate = tomorrow
        }
        PreExamReviewPlanner.invalidate(context: context)
        do {
            try context.save()
            usageSink("unpark", ["qid": questionID])
            return true
        } catch {
            r.parked = true
            r.parkedAt = previous.0
            r.dueDate = previous.1
            r.resumeDueDate = previous.2
            return false
        }
    }

    // MARK: Custom practice

    /// Seen questions and open (unmastered) mistakes by urgency, for 自選練習.
    func practiceHistory(now: Date = .now) -> CustomPractice.History {
        let records = allRecords()
        var h = CustomPractice.History()
        h.seen = Set(records.map(\.questionID))
        func due(_ r: QuestionRecord) -> Date { r.reviewStatus(using: scheduler, at: now).nextReviewDate ?? .distantPast }
        h.openOrder = records.filter { $0.isOpenMistake(using: scheduler, at: now) }
            .map { ($0.questionID, due($0)) }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0)
        return h
    }

    // MARK: Mock exams

    func finishedExams() -> [MockExam] {
        let d = FetchDescriptor<MockExam>(predicate: #Predicate { $0.finishedAt != nil },
                                          sortBy: [SortDescriptor(\.startedAt)])
        return ((try? context.fetch(d)) ?? []).sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    /// Unfinished single-subject mock (full-mock subjects are resumed from their full mock).
    func unfinishedExam() -> MockExam? {
        let d = FetchDescriptor<MockExam>(predicate: #Predicate { $0.finishedAt == nil && $0.fullMockID == nil },
                                          sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try? context.fetch(d).first
    }

    func scoreEntries() -> [ScoreHistory.Entry] {
        ScoreHistory.entries(from: finishedExams())
    }

    /// Paper ids ("<code>_<subject>") already finished as whole-paper mocks.
    func takenPaperIDs() -> Set<String> {
        Set(finishedExams().compactMap { e in
            guard e.mode == .wholePaper, let code = e.paperCode else { return nil }
            return Paper.makeID(code: code, subject: e.subject)
        })
    }

    /// Scores the exam, marks it finished and records every answered question as an attempt,
    /// so wrong answers enter the mistake book through the scheduler. Unanswered questions are not recorded.
    /// Full-mock subjects are only submitted here (score kept hidden, nothing recorded) until the fifth subject is done.
    @discardableResult
    func finish(exam: MockExam, bank: QuestionBank, elapsed: Double, auto: Bool, now: Date = .now) -> ExamScore {
        let qs = exam.questionIDs.compactMap { bank.byID[$0] }
        let result = ExamScoring.score(questions: qs, answers: exam.answers)
        guard !exam.isSubmitted else { return result }
        exam.elapsed = min(elapsed, ExamRules.durationSeconds)
        exam.autoSubmitted = auto
        exam.correctCount = result.correct
        exam.score = result.score
        if exam.isFullMockPart {
            exam.submittedAt = now
        } else {
            exam.finishedAt = now
            recordAttempts(of: exam, questions: qs, at: now)
        }
        try? context.save()
        usageSink("exam_submit", ["examId": exam.examID.uuidString, "subject": exam.subject, "mode": exam.modeRaw,
            "answered": exam.answeredCount, "count": exam.questionIDs.count, "score": exam.score,
            "seconds": exam.elapsed, "counted": exam.countsTowardScores])
        return result
    }

    func recordAttempts(of exam: MockExam, questions qs: [Question], at time: Date) {
        let plan = preExamPlan(at: time)
        for (i, q) in qs.enumerated() where i < exam.answers.count && !exam.answers[i].isEmpty {
            let a = exam.answers[i]
            commit(question: q, chosen: a, correct: ExamScoring.isCorrect(answer: a, question: q),
                   unsure: false, reason: exam.reasons.indices.contains(i) && !exam.reasons[i].isEmpty ? exam.reasons[i] : nil,
                   source: AttemptRecord.examSource, seconds: exam.seconds.indices.contains(i) ? exam.seconds[i] : nil,
                   usageSource: exam.isFullMockPart ? "fullMock" : "exam", precomputedPlan: plan, now: time)
        }
    }

    /// Creates and saves a new mock exam. Returns nil when no questions are available.
    func makeExam(subject: String, mode: ExamMode, paper: Paper?, bank: QuestionBank,
                  includeSpecial: Bool, now: Date = .now) -> MockExam? {
        var ids: [String] = []
        var title = mode.rawValue
        switch mode {
        case .wholePaper:
            guard let paper else { return nil }
            ids = paper.questionIDs
            title = paper.label
        case .random:
            var rng = SystemRandomNumberGenerator()
            let seen = Set(allRecords().map(\.questionID))
            ids = ExamBuilder.randomMix(pool: subjectPool(subject, bank: bank, includeSpecial: includeSpecial).map(\.id),
                                        seen: seen, using: &rng)
        case .mistakes:
            ids = mistakeFocusIDs(subject: subject, bank: bank, includeSpecial: includeSpecial, now: now).shuffled()
        }
        guard !ids.isEmpty else { return nil }
        let exam = MockExam(subject: subject, mode: mode, paperCode: mode == .wholePaper ? paper?.code : nil,
                            title: title, questionIDs: ids, now: now)
        var orderRNG = SystemRandomNumberGenerator()
        exam.optionOrders = ExamBuilder.optionOrders(for: ids.compactMap { bank.byID[$0] }, mode: mode, using: &orderRNG)
        context.insert(exam)
        try? context.save()
        usageSink("exam_start", ["examId": exam.examID.uuidString, "subject": exam.subject,
                                 "mode": exam.modeRaw, "count": exam.questionIDs.count])
        return exam
    }

    func subjectPool(_ subject: String, bank: QuestionBank, includeSpecial: Bool) -> [Question] {
        bank.reviewPool(includeSpecial: includeSpecial).filter { $0.subject == subject }
    }

    /// Open mistakes of the subject (in the active pool).
    func openMistakeIDs(subject: String, bank: QuestionBank, includeSpecial: Bool, now: Date = .now) -> [String] {
        let pool = Set(subjectPool(subject, bank: bank, includeSpecial: includeSpecial).map(\.id))
        func due(_ r: QuestionRecord) -> Date {
            r.reviewStatus(using: scheduler, at: now).nextReviewDate ?? .distantPast
        }
        return allRecords()
            .filter { $0.isOpenMistake(using: scheduler, at: now) && pool.contains($0.questionID) }
            .sorted { (due($0), $0.questionID) < (due($1), $1.questionID) }
            .map(\.questionID)
    }

    /// 錯題加強: open mistakes, then questions missed before (now mastered), then unseen, then the rest.
    func mistakeFocusIDs(subject: String, bank: QuestionBank, includeSpecial: Bool, now: Date = .now) -> [String] {
        let open = openMistakeIDs(subject: subject, bank: bank, includeSpecial: includeSpecial, now: now)
        let records = Dictionary(allRecords().map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
        let pool = subjectPool(subject, bank: bank, includeSpecial: includeSpecial).filter { records[$0.id]?.parked != true }
        var rng = SystemRandomNumberGenerator()
        let weak = pool.filter { q in
            guard let r = records[q.id], r.isMastered(using: scheduler, at: now) else { return false }
            return (r.attempts ?? []).contains { !$0.correct || $0.unsure }
        }.map(\.id).shuffled(using: &rng)
        let fresh = pool.filter { records[$0.id] == nil }.map(\.id).shuffled(using: &rng)
        let rest = pool.filter { records[$0.id] != nil }.map(\.id).shuffled(using: &rng)
        return ExamBuilder.mistakeFocus(open: open, weak: weak, fresh: fresh + rest)
    }

    /// Sets the wrong-answer reason chosen while reviewing a finished exam.
    func setReason(_ reason: String?, exam: MockExam, index: Int) {
        guard index < exam.questionIDs.count else { return }
        exam.reasons[index] = reason ?? ""
        let id = exam.questionIDs[index]
        if let finished = exam.finishedAt {
            let d = FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.questionID == id && $0.timestamp == finished })
            for a in (try? context.fetch(d)) ?? [] where !a.correct { a.reason = reason }
            if let rec = record(for: id), rec.lastAnswered == finished { rec.lastReason = reason }
        }
        try? context.save()
    }

    // MARK: Full mock

    func unfinishedFullMock() -> FullMock? {
        let d = FetchDescriptor<FullMock>(predicate: #Predicate { $0.finishedAt == nil },
                                          sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try? context.fetch(d).first
    }

    func finishedFullMocks() -> [FullMock] {
        let d = FetchDescriptor<FullMock>(predicate: #Predicate { $0.finishedAt != nil },
                                          sortBy: [SortDescriptor(\.startedAt)])
        return (try? context.fetch(d)) ?? []
    }

    /// Subject exams of a full mock in official subject order (only the ones started so far).
    func subjectExams(of full: FullMock) -> [MockExam] {
        let id = full.fullID
        let d = FetchDescriptor<MockExam>(predicate: #Predicate { $0.fullMockID == id })
        let exams = (try? context.fetch(d)) ?? []
        return exams.sorted { order($0.subject) < order($1.subject) }
    }

    private func order(_ subject: String) -> Int { Subjects.all.firstIndex(of: subject) ?? Subjects.all.count }

    func startFullMock(session: ExamSession, now: Date = .now) -> FullMock {
        let full = FullMock(code: session.code, label: session.label, now: now)
        context.insert(full)
        try? context.save()
        return full
    }

    /// Creates the exam of the next subject (or returns the one already started and not yet submitted).
    func nextSubjectExam(of full: FullMock, bank: QuestionBank, now: Date = .now) -> MockExam? {
        let exams = subjectExams(of: full)
        if let open = exams.first(where: { !$0.isSubmitted }) { return open }
        guard exams.count < Subjects.all.count else { return nil }
        let subject = Subjects.all[exams.count]
        guard let paper = bank.paperByID[Paper.makeID(code: full.code, subject: subject)] else { return nil }
        let exam = MockExam(subject: subject, mode: .wholePaper, paperCode: full.code,
                            title: "\(full.label) 連考第 \(exams.count + 1) 科", questionIDs: paper.questionIDs, now: now)
        exam.fullMockID = full.fullID
        exam.optionOrders = Array(repeating: "", count: paper.questionIDs.count)
        context.insert(exam)
        full.breakStartedAt = nil
        try? context.save()
        usageSink("exam_start", ["examId": exam.examID.uuidString, "subject": exam.subject,
                                 "mode": exam.modeRaw, "count": exam.questionIDs.count])
        return exam
    }

    /// After the fifth subject: publish scores and feed every answer to the scheduler (timestamped at its submission).
    func completeFullMock(_ full: FullMock, bank: QuestionBank, now: Date = .now) {
        let exams = subjectExams(of: full)
        guard exams.count == Subjects.all.count, exams.allSatisfy(\.isSubmitted), !full.isFinished else { return }
        for exam in exams where exam.finishedAt == nil {
            let t = exam.submittedAt ?? now
            exam.finishedAt = t
            recordAttempts(of: exam, questions: exam.questionIDs.compactMap { bank.byID[$0] }, at: t)
        }
        full.finishedAt = now
        full.breakStartedAt = nil
        try? context.save()
        let scores = Dictionary(exams.map { ($0.subject, $0.score) }, uniquingKeysWith: { a, _ in a })
        let average = Double(scores.values.reduce(0, +)) / Double(scores.count)
        usageSink("fullmock_submit", ["fullId": full.fullID.uuidString, "average": average,
                                      "passed": average >= 60 && scores.values.allSatisfy { $0 > 0 }, "scores": scores])
    }

    // MARK: Bookmarks and notes

    func note(for id: String) -> QuestionNote? {
        let d = FetchDescriptor<QuestionNote>(predicate: #Predicate { $0.questionID == id })
        return (try? context.fetch(d))?.sorted(by: StudyDeduplication.noteOrder).first
    }

    private func noteOrCreate(for q: Question, now: Date) -> QuestionNote {
        if let n = note(for: q.id) { return n }
        let n = QuestionNote(questionID: q.id, subject: q.subject, now: now)
        context.insert(n)
        return n
    }

    func setBookmark(_ on: Bool, question q: Question, now: Date = .now) {
        let n = noteOrCreate(for: q, now: now)
        n.bookmarked = on
        n.updatedAt = now.wholeMillisecond
        try? context.save()
    }

    func setNote(_ text: String, question q: Question, now: Date = .now) {
        if text.isEmpty, note(for: q.id) == nil { return }
        let n = noteOrCreate(for: q, now: now)
        n.text = text
        n.updatedAt = now.wholeMillisecond
        try? context.save()
    }

    /// 錯題本 card marks: questions with a pending 再次挑戰 today (same rule as the 今日 card), and questions
    /// whose latest answer was a correct guess (「猜的」).
    func mistakeMarks(now: Date = .now) -> (retryToday: Set<String>, guessed: Set<String>) {
        let attempts = allAttempts().filter { $0.timestamp <= now }.sorted(by: StudyReplay.attemptOrder)
        let parked = Set(allRecords().filter(\.parked).map(\.questionID))
        let retry = RetryQueue.rebuild(attempts: attemptFacts(from: attempts), now: now, calendar: scheduler.calendar,
                                       excluding: parked)
        var latest: [String: AttemptRecord] = [:]
        for a in attempts { latest[a.questionID] = a }
        let guessed = latest.values.filter { $0.correct && $0.unsure }.map(\.questionID)
        return (Set(retry), Set(guessed))
    }

    // MARK: Study log

    func attemptFacts() -> [AttemptFact] {
        attemptFacts(from: allAttempts())
    }

    private func attemptFacts(from attempts: [AttemptRecord]) -> [AttemptFact] {
        attempts.sorted(by: StudyReplay.attemptOrder).map {
            AttemptFact(questionID: $0.questionID, timestamp: $0.timestamp, correct: $0.correct,
                        fromExam: $0.source == AttemptRecord.examSource)
        }
    }

    func weeklyDays(goal: Int, now: Date = .now) -> [WeeklyGoal.Day] {
        WeeklyGoal.week(attempts: attemptFacts(), goal: goal, now: now, calendar: scheduler.calendar)
    }

    func mistakeCategories(now: Date = .now) -> MistakeCategories.Result {
        MistakeCategories.compute(records: allRecords().map {
            .init(questionID: $0.questionID, schedule: $0.schedule, parked: $0.parked)
        }, attempts: allAttempts().sorted(by: StudyReplay.attemptOrder).map {
            .init(questionID: $0.questionID, timestamp: $0.timestamp,
                  outcome: ReviewOutcome(correct: $0.correct, unsure: $0.unsure), retry: $0.retry,
                  masteredBefore: $0.masteredBefore)
        }, scheduler: scheduler, now: now)
    }

    func studyActivity(now: Date = .now) -> StudyTime.Summary {
        studyActivity(attempts: attemptFacts(), now: now)
    }

    private func studyActivity(attempts: [AttemptFact], now: Date) -> StudyTime.Summary {
        let exams = (try? context.fetch(FetchDescriptor<MockExam>())) ?? []
        let mocks = exams.map { exam in
            StudyTime.MockTime(date: exam.submittedAt ?? exam.finishedAt ?? exam.startedAt,
                               seconds: exam.seconds.prefix(exam.questionIDs.count)
                                .filter { $0.isFinite && $0 > 0 }.reduce(0, +))
        }
        return StudyTime.compute(attempts: attempts, mocks: mocks, now: now, calendar: scheduler.calendar)
    }

    func mistakeDigest(now: Date = .now) -> MistakeDigest {
        var d = MistakeDigest(mastered: 0, reviewing: 0)
        for r in allRecords() where r.schedule.isMistake {
            if r.isMastered(using: scheduler, at: now) { d.mastered += 1 }
            else if r.isOpenMistake(using: scheduler, at: now) { d.reviewing += 1 }
        }
        return d
    }

    func deleteAll() {
        try? context.delete(model: FullMock.self)
        try? context.delete(model: QuestionNote.self)
        try? context.delete(model: MockExam.self)
        try? context.delete(model: AttemptRecord.self)
        try? context.delete(model: QuestionRecord.self)
        try? context.save()
    }
}
