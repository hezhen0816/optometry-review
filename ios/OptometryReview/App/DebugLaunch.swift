import Foundation
import SwiftUI
import SwiftData

/// DEBUG-only launch arguments for simulator walkthroughs. Release builds ignore all of them.
///   -resetAll   clear settings, tips, study data and the nightly-analysis snapshot
///   -seedDemo   finish onboarding and insert sample mistakes (only when the store is empty)
///   -tipsShown  mark all coach marks and the current 「新功能」 sheet as seen
///   -secondDevice  with -resetAll: store an exam date and daily goal, as if iCloud had delivered them (second-device page)
///   -seedMocks  insert eight finished single-subject mocks over the past weeks (only when none exist)
///   -tab N      open on tab N (0 今日, 1 單元, 2 錯題本, 3 模擬考, 4 成績)
///   -examFillAnswers  when an exam opens, answer the untouched questions (about 70 % right, two left blank)
///   -examAlmostOver   when an exam opens, leave 8 seconds on the clock (to see the auto-submit)
///   -examElapsed <seconds>  when an exam opens, start the clock as if that much time had passed (intro video)
///   -openQuestion <code>_<subject>_<n>   open a practice session starting at that question of its paper
///   -seedAI       AI answers: three wrong (AI 錯題) and three right, over the last days (only when none exist)
///   -openHandout <unit>[#<point>]  open that unit's 重點講義 (point ids look like 低視力學-1.1#2) over the tabs
///   -askPrefill "q1|q2|…"  問講義: prefill the question field with the next canned question after each send
///   -openAI <n|all>  open an AI practice round with the first n AI questions (or all)
///   -figureGallery <i,j,…>  show the debug figure gallery for the listed cases (0…15)
///   -seedHistory  answer history over the last five weeks (heatmap, weekly goal, accuracy split; only when empty)
///   -seedDemoLight  real FSRS histories, mastered cards, and fourteen due cards after four answers today
///                   (intro video; only when empty)
///   -resetAI    clear the on-device AI explanation cache and 問講義 conversations (-resetAll clears them too)
///   -corruptStore  overwrite the store before opening to exercise backup and recovery
///   -aiBaseURL <url>  send AI requests to another server, e.g. a local stub (read in AIConfig.load)
///   -aiToken <text>  pretend an AI key is bundled (shows 檢討這回 etc.); use with -aiBaseURL pointing at an unused local port
///   -seedAIMarkers  cache sample AI explanations for 115 視覺光學 2 (〔X〕 markers and a follow-up) and 6 (old style,
///                   bare letters) so the panel's letter mapping can be checked without a server
///   -fakeLatest <latest>,<min>  fake the /app/latest answer (either may be empty); -fakeBuild <n> pretends to be that build
///   -seedFullMock pass,fail,progress   finished full mocks (114 年 及格, 112 年 未達 with a 0-point subject)
///                 and/or one in progress (113 年, two subjects submitted, break running)
enum DebugLaunch {
    static var initialTab: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        #endif
        return 0
    }

    /// Practice queue requested by -openQuestion: the rest of the paper from that question on.
    static func openQuestionQueue(bank: QuestionBank) -> [String]? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openQuestion"), i + 1 < args.count,
              let q = bank.byID[args[i + 1]], let paper = bank.paper(for: q),
              let start = paper.questionIDs.firstIndex(of: q.id) else { return nil }
        return Array(paper.questionIDs[start...])
        #else
        return nil
        #endif
    }

    #if DEBUG
    @MainActor
    static func fillExamAnswers(_ exam: MockExam, questions: [Question]) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-examAlmostOver") { exam.elapsed = max(exam.elapsed, ExamRules.durationSeconds - 8) }
        if let i = args.firstIndex(of: "-examElapsed"), i + 1 < args.count, let s = Double(args[i + 1]) {
            exam.elapsed = max(exam.elapsed, min(s, ExamRules.durationSeconds - 60))
        }
        guard args.contains("-examFillAnswers") else { return }
        for (i, q) in questions.enumerated() where i < exam.answers.count && exam.answers[i].isEmpty {
            if i >= questions.count - 2 { continue }
            let right = q.answer.first ?? "A"
            let wrong = Question.letters.first { !q.answer.contains($0) } ?? "A"
            exam.answers[i] = (i * 7) % 10 < 7 ? right : wrong
            exam.seconds[i] = 30 + Double((i * 53) % 90)
        }
        exam.currentIndex = max(exam.currentIndex, questions.count - 3)
    }

    static func apply(container: ModelContainer, bank: QuestionBank,
                      arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard, now: Date = .now) {
        let args = Set(arguments)
        MainActor.assumeIsolated {
            let context = container.mainContext
            if args.contains("-resetAll") {
                for key in [SettingsKey.onboarded, SettingsKey.examDate, SettingsKey.dailyGoal, SettingsKey.includeSpecial,
                            SettingsKey.yearFrom, SettingsKey.yearTo, SettingsKey.reminderEnabled, SettingsKey.reminderMinutes,
                            ScopeStore.dailyKey, ScopeStore.customKey, SettingsKey.newRatioMode, SettingsKey.customNewPercent,
                            SettingsKey.usageLogEnabled, WhatsNewSheet.shownKey, OnboardingFlow.whatsNewZeroThreeTwoKey, LeaderboardModel.joinedKey,
                            LeaderboardModel.nameKey, LeaderboardModel.promptedKey, LeaderboardModel.pendingLeaveKey, AIPractice.hiddenFiguresKey,
                            SettingsKey.detailHidesAnswer, OnboardingFlow.tourDoneKey, OnboardingFlow.setupStartedKey]
                    + SettingsKey.allTips + YearFilterStore.Screen.allCases.map(YearFilterStore.key) + YearFilterStore.legacyKeys {
                    defaults.removeObject(forKey: key)
                }
                defaults.removeObject(forKey: InsightsStore.fetchLogKey)
                defaults.removeObject(forKey: UpdateNoticeStore.dismissedKey)
                InsightsStore.shared.set(nil)
                StudyStore(context: context).deleteAll()
            }
            if args.contains("-resetAll") || args.contains("-resetAI") {
                AICacheStore(context: context).deleteAll()
                HandoutAskStore().clearAll()
                HandoutAsker.shared?.reloadFromDisk()
            }
            if args.contains("-seedAIMarkers") {
                seedAIMarkers(context: context, bank: bank)
            }
            if args.contains("-secondDevice") {
                // A study plan that "arrived from iCloud" on a device that was never onboarded.
                defaults.set(Calendar.current.date(byAdding: .day, value: 120, to: now)!.timeIntervalSince1970,
                             forKey: SettingsKey.examDate)
                defaults.set(25, forKey: SettingsKey.dailyGoal)
            }
            if args.contains("-tipsShown") {
                for key in SettingsKey.allTips { defaults.set(true, forKey: key) }
                OnboardingFlow.markWhatsNewSeen(defaults: defaults)
            }
            if args.contains("-seedDemo") {
                seed(context: context, bank: bank, defaults: defaults, now: now)
                seedMocks(context: context, bank: bank, defaults: defaults, now: now)
            }
            if args.contains("-seedMocks") {
                seedMocks(context: context, bank: bank, defaults: defaults, now: now)
            }
            if args.contains("-seedAI") {
                seedAI(context: context, bank: bank, now: now)
            }
            if args.contains("-seedHistory") {
                seedHistory(context: context, bank: bank, defaults: defaults, now: now)
            }
            if args.contains("-seedDemoLight"), StudyStore(context: context).allAttempts().isEmpty {
                seedMocks(context: context, bank: bank, defaults: defaults, now: now)
                try? StudyReplay.run(context: context, scheduler: fixtureScheduler(defaults))
                seedDemoLight(context: context, bank: bank, defaults: defaults, now: now)
            }
            let list = arguments
            if let i = list.firstIndex(of: "-seedFullMock"), i + 1 < list.count {
                let kinds = Set(list[i + 1].split(separator: ",").map(String.init))
                if kinds.contains("progress") { seedMocks(context: context, bank: bank, defaults: defaults, now: now) }
                seedFullMocks(kinds, context: context, bank: bank, defaults: defaults, now: now)
            }
            try? StudyReplay.run(context: context, scheduler: fixtureScheduler(defaults))
        }
    }

    @MainActor
    private static func seedAI(context: ModelContext, bank: QuestionBank, now: Date) {
        let store = StudyStore(context: context, usageSink: { _, _ in })
        guard store.aiAttempts().isEmpty else { return }
        let qs = bank.ai.questions
        // (question index, chosen letter or "" for a correct pick, days ago)
        let plan: [(Int, Bool, Int)] = [(0, false, 0), (3, false, 1), (5, false, 3), (6, false, 4), (1, true, 1), (2, true, 2), (4, true, 5), (9, true, 0)]
        for (i, correct, ago) in plan where qs.indices.contains(i) {
            let q = qs[i]
            let wrong = Question.letters.first { $0 != q.answer } ?? "A"
            let t = now.addingTimeInterval(-Double(ago) * 86_400 - Double(i) * 60)
            store.commitAI(question: q, chosen: correct ? q.answer : wrong, unsure: false, now: t)
        }
    }

    /// Canned questions of `-askPrefill`, separated by `|`.
    static var askPrefill: [String] {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-askPrefill"), i + 1 < args.count else { return [] }
        return args[i + 1].split(separator: "|").map(String.init)
        #else
        return []
        #endif
    }

    /// The handout of an `-openHandout <unit>` request; a point id (which contains `#`) is accepted as `<unit>#<n>`.
    static func openHandoutRoute(bank: QuestionBank) -> HandoutRoute? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openHandout"), i + 1 < args.count else { return nil }
        let raw = args[i + 1]
        if bank.learning.pointByID[raw] != nil, let unit = raw.split(separator: "#").first {
            return HandoutRoute(unitID: String(unit), pointID: raw)
        }
        return bank.learning.handouts[raw] != nil ? HandoutRoute(unitID: raw) : nil
        #else
        return nil
        #endif
    }

    /// The AI questions of an `-openAI` request.
    static func openAIQueue(bank: QuestionBank) -> [String]? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openAI"), i + 1 < args.count else { return nil }
        let all = bank.ai.questions.map(\.id)
        if args[i + 1] == "all" { return all }
        return Array(all.prefix(Int(args[i + 1]) ?? 3))
    }

    /// Figure cases for `-figureGallery`: indices into `figureCases`.
    static func figureGalleryCases() -> [Int]? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-figureGallery"), i + 1 < args.count else { return nil }
        return args[i + 1].split(separator: ",").compactMap { Int($0) }
    }

    @MainActor
    private static func seedAIMarkers(context: ModelContext, bank: QuestionBank) {
        let cache = AICacheStore(context: context)
        if let q = bank.byID[Question.makeID(code: "115100", subject: "視覺光學", number: 2)] {
            let lines = Question.letters.map { "〔\($0)〕\(q.options[$0] ?? "")" }.joined(separator: "、")
            let text = "示範解析（新格式）：正確答案是〔\(q.answer.first ?? "A")〕。各選項：\(lines)。+10D 這類度數不受影響。"
            let e = cache.save(AIExplainResult(text: text, version: 1, createdAt: "", cached: true), for: q.id)
            e.followups = [AIChatTurn(role: .user, text: "為什麼 A 不對？"),
                           AIChatTurn(role: .assistant, text: "示範追問回答：〔A〕\(q.options["A"] ?? "") 不符合題意，〔B〕才對。")]
            try? context.save()
        }
        if let q = bank.byID[Question.makeID(code: "115100", subject: "視覺光學", number: 6)] {
            let text = "示範解析（舊格式）：正確答案是 \(q.answer.first ?? "A")，A 是\(q.options["A"] ?? "")。"
            cache.save(AIExplainResult(text: text, version: 1, createdAt: "", cached: true), for: q.id)
        }
    }

    @MainActor
    private static func seed(context: ModelContext, bank: QuestionBank, defaults: UserDefaults, now: Date) {
        defaults.set(true, forKey: SettingsKey.onboarded)
        defaults.set(Calendar.current.date(byAdding: .day, value: 90, to: now)!.timeIntervalSince1970, forKey: SettingsKey.examDate)
        guard StudyStore(context: context).allRecords().isEmpty else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let pool = bank.reviewPool(includeSpecial: false)
            .filter { $0.code == "115100" && !$0.hasFigure && !$0.needsFigureNotice && !$0.allCredit }
        for (index, q) in pool.prefix(12).enumerated() {
            let date = cal.date(byAdding: .day, value: index < 8 ? -2 : 0, to: today)!.addingTimeInterval(9 * 3600)
            appendAnswer(q, correct: false, at: date, reason: MistakeReason.all[index % MistakeReason.all.count], context: context)
        }
        if let q = bank.byID[Question.makeID(code: "114100", subject: "視覺光學", number: 49)] {
            appendAnswer(q, correct: false, at: cal.date(byAdding: .day, value: -1, to: today)!,
                         reason: "觀念不懂", context: context)
        }
        try? context.save()
        try? StudyReplay.run(context: context, scheduler: fixtureScheduler(defaults))
        seedMasteredQuestions(Array(pool.dropFirst(12).prefix(6)), context: context, defaults: defaults, now: now)
    }

    /// Finished whole-paper mocks: (subject index, paper code, correct count, days ago).
    /// Finished mocks also write answer histories for the same FSRS replay as live mock grading.
    @MainActor
    private static func seedMocks(context: ModelContext, bank: QuestionBank, defaults: UserDefaults, now: Date) {
        defaults.set(true, forKey: SettingsKey.onboarded)
        let existing = (try? context.fetch(FetchDescriptor<MockExam>())) ?? []
        guard existing.isEmpty else { return }
        let plan: [(Int, String, Int, Int)] = [
            (1, "110111", 26, 49), (2, "110111", 27, 42), (0, "110111", 33, 35), (3, "110111", 28, 28),
            (4, "110111", 21, 21), (1, "111110", 31, 14), (4, "111110", 24, 7), (2, "111110", 33, 2),
        ]
        let cal = Calendar.current
        for (si, code, correct, daysAgo) in plan {
            guard let paper = bank.paperByID[Paper.makeID(code: code, subject: Subjects.all[si])] else { continue }
            let qs = bank.questions(of: paper)
            let start = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            let exam = MockExam(subject: paper.subject, mode: .wholePaper, paperCode: code, title: paper.label,
                                questionIDs: paper.questionIDs, now: start)
            for (i, q) in qs.enumerated() {
                let right = q.answer.first ?? "A"
                let wrong = Question.letters.first { !q.answer.contains($0) } ?? "A"
                exam.answers[i] = i < correct ? right : (i % 7 == 0 ? "" : wrong)
                exam.seconds[i] = 40 + Double((i * 37) % 80)
            }
            let result = ExamScoring.score(questions: qs, answers: exam.answers)
            exam.correctCount = result.correct
            exam.score = result.score
            exam.elapsed = 2_900 + Double(daysAgo * 13)
            exam.finishedAt = start.addingTimeInterval(exam.elapsed)
            exam.currentIndex = qs.count - 1
            context.insert(exam)
            appendExamAnswers(exam, questions: qs, context: context)
        }
        try? context.save()
    }

    /// Five weeks of daily answering through the real scheduler: goal reached on most days, a few rest days,
    /// a partial today, and one day with a 50-question mock.
    @MainActor
    private static func seedHistory(context: ModelContext, bank: QuestionBank, defaults: UserDefaults, now: Date) {
        defaults.set(true, forKey: SettingsKey.onboarded)
        let store = StudyStore(context: context, scheduler: fixtureScheduler(defaults), defaults: defaults, usageSink: { _, _ in })
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let cutoff = cal.date(byAdding: .day, value: -20, to: today)!
        guard !store.allAttempts().contains(where: { $0.timestamp < cutoff }) else { return }
        let weekStart = WeeklyGoal.weekStart(of: now, calendar: cal)
        let first = cal.date(byAdding: .day, value: -28, to: weekStart)!
        let pattern = [20, 18, 0, 25, 22, 30, 0, 20, 21, 15, 0, 20, 35, 10, 20, 22, 20, 8, 0, 20, 40, 20, 21, 20, 25, 20, 30, 45]
        var rng = SeededGenerator(seed: 42)
        var fresh = bank.reviewPool(includeSpecial: false).filter { !$0.optionsAsImage }.shuffled(using: &rng)
        var seenIDs: [String] = []
        var day = first
        var i = 0
        while day <= today {
            let n: Int
            if day == today { n = 6 } else if day >= weekStart { n = 20 + (i % 3) } else { n = pattern[i % pattern.count] }
            for k in 0..<n {
                let reuse = !seenIDs.isEmpty && Int.random(in: 0..<10, using: &rng) < 4
                let q: Question
                if reuse, let id = seenIDs.randomElement(using: &rng), let hit = bank.byID[id] { q = hit } else if !fresh.isEmpty {
                    q = fresh.removeFirst()
                    seenIDs.append(q.id)
                } else { continue }
                let correct = Int.random(in: 0..<100, using: &rng) < (reuse ? 80 : 62)
                let chosen = correct ? (q.answer.first ?? "A") : (Question.letters.first { !q.answer.contains($0) } ?? "A")
                let t = day.addingTimeInterval(Double(9 * 3600 + k * 70))
                store.commit(question: q, chosen: chosen, correct: correct, unsure: false,
                             reason: correct ? nil : MistakeReason.all[k % MistakeReason.all.count], now: t)
            }
            if i == 12 {
                for k in 0..<50 where !fresh.isEmpty {
                    let q = fresh.removeFirst()
                    let correct = k % 3 != 0
                    let chosen = correct ? (q.answer.first ?? "A") : (Question.letters.first { !q.answer.contains($0) } ?? "A")
                    store.commit(question: q, chosen: chosen, correct: correct, unsure: false, reason: nil,
                                 source: AttemptRecord.examSource, now: day.addingTimeInterval(Double(14 * 3600 + k * 60)))
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
            i += 1
        }
    }

    /// An FSRS-backed demo with a controlled Today backlog and real mastered histories.
    @MainActor
    private static func seedDemoLight(context: ModelContext, bank: QuestionBank, defaults: UserDefaults, now: Date) {
        defaults.set(true, forKey: SettingsKey.onboarded)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        defaults.set(cal.date(byAdding: .day, value: 90, to: today)!.timeIntervalSince1970, forKey: SettingsKey.examDate)
        let store = StudyStore(context: context, scheduler: fixtureScheduler(defaults), defaults: defaults, usageSink: { _, _ in })
        // Catch up historical mock mistakes at their actual FSRS due days, never by assigning arbitrary state.
        for record in store.allRecords() {
            guard let q = bank.byID[record.questionID] else { continue }
            var reviews = 0
            while let due = store.scheduler.effectiveDue(record.schedule, now: today),
                  due < today, reviews < 100 {
                let time = max(due.addingTimeInterval(9 * 3600), record.lastReview ?? due)
                store.commit(question: q, chosen: q.answer.first ?? "A", correct: true, unsure: false,
                             reason: nil, now: time)
                reviews += 1
            }
        }
        let seen = Set(store.allRecords().map(\.questionID))
        let fresh = bank.reviewPool(includeSpecial: false)
            .filter { $0.code == "115100" && !$0.optionsAsImage && !$0.allCredit && !seen.contains($0.id) }
        seedMasteredQuestions(Array(fresh.prefix(6)), context: context, defaults: defaults, now: now)
        // Eighteen due cards, then four answered today, leave fourteen for the walkthrough.
        var due = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: now).plan.dueIDs
        let firstToday = max(today.addingTimeInterval(60), now.addingTimeInterval(-900))
        for (index, id) in due.dropFirst(18).enumerated() {
            guard let q = bank.byID[id] else { continue }
            store.commit(question: q, chosen: q.answer.first ?? "A", correct: true, unsure: false,
                         reason: nil, now: firstToday.addingTimeInterval(Double(index)))
        }
        due = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: now).plan.dueIDs
        for q in fresh.dropFirst(6).prefix(max(0, 18 - due.count)) {
            store.commit(question: q, chosen: wrongLetter(q), correct: false, unsure: false, reason: "觀念不懂",
                         now: cal.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(9 * 3600))
        }
        due = store.todaySummary(bank: bank, includeSpecial: false, goal: 20, now: now).plan.dueIDs
        for (index, id) in due.prefix(4).enumerated() {
            guard let q = bank.byID[id] else { continue }
            store.commit(question: q, chosen: q.answer.first ?? "A", correct: true, unsure: false,
                         reason: nil, now: firstToday.addingTimeInterval(Double(index * 75)))
        }
    }

    @MainActor
    private static func seedFullMocks(_ kinds: Set<String>, context: ModelContext, bank: QuestionBank, defaults: UserDefaults, now: Date) {
        defaults.set(true, forKey: SettingsKey.onboarded)
        let existing = (try? context.fetch(FetchDescriptor<FullMock>())) ?? []
        guard existing.isEmpty else { return }
        let cal = Calendar.current
        let sessions = PaperCatalog.sessions(bank.papers, kind: ExamKind.general)
        // (kind, session code, correct counts per subject or nil = not taken, days ago)
        let plans: [(String, String, [Int?], Int)] = [
            ("pass", "114100", [35, 31, 31, 33, 24], 9),
            ("fail", "112110", [45, 40, 40, 40, 0], 4),
            ("progress", "113100", [36, 30, nil, nil, nil], 0),
        ]
        for (kind, code, counts, daysAgo) in plans where kinds.contains(kind) {
            guard let session = sessions.first(where: { $0.code == code }) else { continue }
            let start = cal.date(byAdding: .day, value: -daysAgo, to: now)!.addingTimeInterval(kind == "progress" ? -7_800 : -36_000)
            let full = FullMock(code: code, label: session.label, now: start)
            context.insert(full)
            var t = start
            for (si, correct) in counts.enumerated() {
                guard let correct, let paper = session.papers.first(where: { $0.subject == Subjects.all[si] }) else { continue }
                let qs = bank.questions(of: paper)
                let exam = MockExam(subject: paper.subject, mode: .wholePaper, paperCode: code,
                                    title: "\(session.label) 連考第 \(si + 1) 科", questionIDs: paper.questionIDs, now: t)
                exam.fullMockID = full.fullID
                exam.optionOrders = Array(repeating: "", count: qs.count)
                for (i, q) in qs.enumerated() {
                    let right = q.answer.first ?? "A"
                    let wrong = Question.letters.first { !q.answer.contains($0) } ?? "A"
                    // Blank all-credit questions preserve the intentional zero-score demo; the rest are answered.
                    exam.answers[i] = correct == 0 && q.allCredit ? "" : (i < correct ? right : wrong)
                    exam.seconds[i] = 40 + Double((i * 37) % 80)
                }
                let result = ExamScoring.score(questions: qs, answers: exam.answers)
                exam.correctCount = result.correct
                exam.score = result.score
                exam.elapsed = 2_800 + Double(si * 61)
                exam.currentIndex = qs.count - 1
                t = t.addingTimeInterval(exam.elapsed)
                exam.submittedAt = t
                if kind != "progress" { exam.finishedAt = t }
                context.insert(exam)
                if kind != "progress" { appendExamAnswers(exam, questions: qs, context: context) }
                t = t.addingTimeInterval(600)
            }
            if kind == "progress" {
                full.breakStartedAt = now.addingTimeInterval(-75)
            } else {
                full.finishedAt = t
            }
        }
        try? context.save()
    }
    private static func fixtureScheduler(_ defaults: UserDefaults) -> Scheduler {
        let value = defaults.double(forKey: SettingsKey.examDate)
        return Scheduler(examDate: value > 0 ? Date(timeIntervalSince1970: value) : nil)
    }

    private static func wrongLetter(_ q: Question) -> String {
        Question.letters.first { !q.answer.contains($0) } ?? "A"
    }

    @MainActor
    private static func appendAnswer(_ q: Question, correct: Bool, at time: Date, reason: String? = nil,
                                     source: String? = nil, chosen: String? = nil, context: ModelContext) {
        let store = StudyStore(context: context, usageSink: { _, _ in })
        let record: QuestionRecord
        if let existing = store.record(for: q.id) {
            record = existing
            record.firstSeen = min(record.firstSeen, time)
        } else {
            record = QuestionRecord(questionID: q.id, subject: q.subject, now: time)
            context.insert(record)
        }
        let attempt = AttemptRecord(questionID: q.id, subject: q.subject, timestamp: time,
                                    chosen: chosen ?? (correct ? (q.answer.first ?? "A") : wrongLetter(q)),
                                    correct: correct, reason: reason, unsure: false, source: source)
        context.insert(attempt)
        attempt.record = record
        record.fsrsVersion = 0
        if !correct { record.lastReason = reason }
    }

    @MainActor
    private static func appendExamAnswers(_ exam: MockExam, questions: [Question], context: ModelContext) {
        guard let finished = exam.finishedAt else { return }
        for (index, q) in questions.enumerated() where exam.answers.indices.contains(index) && !exam.answers[index].isEmpty {
            let correct = ExamScoring.isCorrect(answer: exam.answers[index], question: q)
            appendAnswer(q, correct: correct, at: finished, source: AttemptRecord.examSource,
                         chosen: exam.answers[index], context: context)
        }
    }

    @MainActor
    private static func seedMasteredQuestions(_ questions: [Question], context: ModelContext,
                                             defaults: UserDefaults, now: Date) {
        let store = StudyStore(context: context, scheduler: fixtureScheduler(defaults), defaults: defaults, usageSink: { _, _ in })
        let today = store.scheduler.calendar.startOfDay(for: now)
        for q in questions {
            let first = store.scheduler.addDays(-60, to: today).addingTimeInterval(9 * 3600)
            store.commit(question: q, chosen: wrongLetter(q), correct: false, unsure: false, reason: "背錯", now: first)
            for _ in 0..<12 {
                guard let record = store.record(for: q.id),
                      !record.isMastered(using: store.scheduler, at: now),
                      let due = record.dueDate, due < today else { break }
                store.commit(question: q, chosen: q.answer.first ?? "A", correct: true, unsure: false, reason: nil,
                             now: due.addingTimeInterval(9 * 3600))
            }
        }
    }

    #endif
}


/// One sample per figure type (and a few variants), for walkthrough screenshots.
struct DebugFigureGallery: View {
    let cases: [Int]
    @Environment(\.dismiss) private var dismiss

    static let specs: [AIFigureSpec] = [
        .init(type: "prentice", params: ["power": .number(-10), "decentrationMM": .number(2), "direction": .text("down"), "eye": .text("OD")]),
        .init(type: "sturm", params: ["sphere": .number(4), "cyl": .number(1), "axis": .number(180)]),
        .init(type: "thinLens", params: ["power": .number(5), "objectCM": .number(30)]),
        .init(type: "vertex", params: ["power": .number(-8), "fromMM": .number(12), "toMM": .number(0)]),
        .init(type: "nearFar", params: ["refraction": .number(-2), "amplitude": .number(6)]),
        .init(type: "tabo", params: ["eye": .text("OD"), "sphere": .number(-2), "cyl": .number(-1.25), "axis": .number(30)]),
        .init(type: "eom", params: ["eye": .text("OD"), "muscle": .text("SR")]),
        .init(type: "visualField", params: ["lesion": .text("chiasm"), "side": .text("L")]),
        // variants
        .init(type: "prentice", params: ["power": .number(4), "decentrationMM": .number(5), "direction": .text("out"), "eye": .text("OS")]),
        .init(type: "sturm", params: ["sphere": .number(3), "cyl": .number(2), "axis": .number(90)]),
        .init(type: "thinLens", params: ["power": .number(5), "objectCM": .number(12)]),
        .init(type: "thinLens", params: ["power": .number(-4), "objectCM": .number(40)]),
        .init(type: "vertex", params: ["power": .number(10), "fromMM": .number(12), "toMM": .number(0)]),
        .init(type: "nearFar", params: ["refraction": .number(-1), "amplitude": .number(5)]),
        .init(type: "eom", params: ["eye": .text("OS"), "muscle": .text("IO")]),
        .init(type: "visualField", params: ["lesion": .text("occipital"), "side": .text("R")]),
        .init(type: "vertex", params: ["power": .number(-7.5), "fromMM": .number(0), "toMM": .number(10)]),
        .init(type: "prentice", params: ["power": .number(-6), "decentrationMM": .number(3), "direction": .text("up"), "eye": .text("OD")]),
        .init(type: "prentice", params: ["power": .number(3), "decentrationMM": .number(4), "direction": .text("up"), "eye": .text("OD")]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(cases, id: \.self) { i in
                    if Self.specs.indices.contains(i), let f = AIFigure.make(Self.specs[i]) {
                        AIFigureFrame(figure: f, onReport: {})
                    }
                }
            }
            .padding(20)
        }
        .readableScrollWidth()
        .background(Palette.ground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button("關閉") { dismiss() }.padding()
        }
    }
}
