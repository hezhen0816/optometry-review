import SwiftUI
import SwiftData

/// Parameters for one review session.
struct SessionRequest: Identifiable, Hashable {
    let id = UUID()
    let queue: [String]
    /// Questions already done today before this session (for the "7 / 20" counter).
    let doneBefore: Int
    let isDaily: Bool
    /// Question-by-question practice of one past paper or a single question.
    var isPractice = false
    /// Practice of a whole past paper (finishes with 「回到試卷」).
    var isPaper = false
    /// 自選練習 (answers are logged with source `custom`).
    var isCustom = false
    /// 「練這科」 from the 今日 progress card: counts toward today's goal (`isDaily`) but logs answers as source `subject`.
    var isSubject = false
    /// Questions answered wrong earlier today (rebuilt after relaunch), shown as 「再練一次」.
    var retryIDs: Set<String> = []
    /// Wrong answers come back three questions later in daily and 自選練習 sessions.
    var retriesWrong: Bool { isDaily || isCustom }
}

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(ScopeStore.dailyKey) private var dailyScopeRaw = ""
    @AppStorage(SettingsKey.newRatioMode) private var ratioRaw = SettingsKey.defaultNewRatioMode
    @AppStorage(SettingsKey.customNewPercent) private var customPercent = SettingsKey.defaultCustomNewPercent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router
    @State private var summary: TodaySummary?
    @State private var session: SessionRequest?
    @State private var showSettings = false
    /// Settings opened from 「設定考試日期」: the date picker starts expanded.
    @State private var settingsEditsDate = false
    @State private var showLog = false
    @State private var weekDays = 0
    @State private var showScope = false
    @State private var customRequest: CustomPracticeRequest?
    @State private var showPractice = false
    /// 「開始練習」 in the 今日練習 sheet: the session starts once the sheet is gone.
    @State private var startAfterSheet = false
    /// Weakest unit (單科分析 rule, all subjects) for the shortcut row; nil without enough answers.
    @State private var aiPractice: AIPracticeRequest?
    /// 最該補的考點 (at most three) under the daily scope; empty hides the card.
    @State private var weakPoints: [PointStat] = []
    /// Reason lines of the nightly analysis by point id (only while it is 36 hours old or younger).
    @State private var weakReasons: [String: String] = [:]
    @State private var handoutRoute: HandoutRoute?
    @State private var showPoints = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let notice = UpdateNoticeStore.shared.notice {
                        UpdateBanner(notice: notice) { UpdateNoticeStore.openTestFlight() } onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) { UpdateNoticeStore.shared.dismiss() }
                        }
                    }
                    header
                    progressCard
                    if let progress = summary?.subjectProgress, progress.contains(where: { $0.total > 0 }) {
                        TodaySubjectProgressCard(progress: progress, onPractice: startSubject)
                    }
                    if !weakPoints.isEmpty {
                        TodayWeakPointsCard(stats: weakPoints, reasons: weakReasons,
                                            onOpen: { handoutRoute = HandoutRoute(unitID: $0.point.unitID, pointID: $0.point.id) },
                                            onPracticeAI: { stat in
                                                let qs = AIPractice.ordered(bank.ai.questions(point: stat.point.id),
                                                                            facts: StudyStore(context: context).aiFacts())
                                                if !qs.isEmpty { aiPractice = AIPracticeRequest(ids: qs.map(\.id)) }
                                            }) {
                            showPoints = true
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .readableScrollWidth()
            .foregroundStyle(Palette.ink)
            .background(Palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(startEditingDate: settingsEditsDate).trackScreen("settings")
            }
            .navigationDestination(isPresented: $showLog) { StudyLogView() }
            .navigationDestination(item: $handoutRoute) { HandoutView(route: $0, backLabel: "返回今日") }
            .navigationDestination(isPresented: $showPoints) { AllPointsView(backLabel: "返回今日") }
            .trackScreen("today")
            .interactivePopEnabled()
            .customPractice($customRequest, onFinish: refresh)
            .sheet(isPresented: $showScope) {
                ScopePickerSheet(initial: dailyScope) { ScopeStore.setDaily($0) }
            }
            .sheet(isPresented: $showPractice, onDismiss: {
                guard startAfterSheet else { return }
                startAfterSheet = false
                primaryAction()
            }) {
                TodayPracticeSheet(summary: summary) {
                    startAfterSheet = true
                    showPractice = false
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: InsightsStore.shared.version) { refresh() }
        .onChange(of: CloudSync.shared.importVersion) { refresh() }
        .onChange(of: router.rootRequest(AppRouter.Tab.today)) {
            showSettings = false
            showLog = false
            handoutRoute = nil
            showPoints = false
        }
        .onChange(of: dailyGoal) { refresh() }
        .onChange(of: includeSpecial) { refresh() }
        .onChange(of: dailyScopeRaw) { refresh() }
        .onChange(of: examDate) { refresh() }
        .onChange(of: ratioRaw) { refresh() }
        .onChange(of: customPercent) { refresh() }
        .fullScreenCover(item: $aiPractice, onDismiss: refresh) { AIPracticeView(request: $0) }
        .fullScreenCover(item: $session, onDismiss: refresh) { req in
            // A follow-up session swaps in place; the id gives it fresh state.
            ReviewSessionView(request: req)
        }
    }

    // MARK: Sections

    /// Date row (date, 距考試, 本週 n／5 天, 設定), then the page title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(DateText.longMonthDay.string(from: .now))
                    .appFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { showLog = true } label: {
                    Text("本週 \(weekDays)／\(WeeklyGoal.targetDays) 天").appFont(13, .bold, relativeTo: .footnote).monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("學習紀錄，本週 \(weekDays) 天有作答，目標 5 天")
                Button {
                    settingsEditsDate = false
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                }
                .accessibilityLabel("設定")
            }
            Text("今日").headingFont(32).lineLimit(1)
        }
    }

    private var progressCard: some View {
        let done = summary?.correctToday ?? 0
        let fresh = summary?.plan.newIDs.count ?? 0
        let due = summary?.reviewOnlyDueCount ?? 0
        let retry = summary?.retryCount ?? 0
        let remaining = summary?.plan.queue.count ?? 0
        let reviewLeft = summary?.reviewCount ?? 0
        let goalMet = summary?.goalMet(dailyGoal) == true
        let fraction = dailyGoal > 0 ? min(1, Double(done) / Double(dailyGoal)) : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                goalLine
                    .appFont(14, relativeTo: .subheadline)
                    .opacity(0.92)
                    .frame(maxWidth: .infinity, alignment: .leading)
                adjustChip
            }
            Button {
                Haptics.selection()
                showPractice = true
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(done)").appFont(52, .bold, relativeTo: .largeTitle).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("/ \(dailyGoal)").appFont(20).opacity(0.85)
                        Text("今天答對").appFont(13, relativeTo: .footnote).opacity(0.9).padding(.leading, 2)
                        Spacer(minLength: 0)
                        // With reviews still due the main button says so; the side label only confirms a finished day.
                        if goalMet && reviewLeft == 0 {
                            Label("今日目標達成", systemImage: "checkmark.circle.fill")
                                .appFont(14, .bold, relativeTo: .subheadline)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * fraction)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
                        }
                    }
                    .frame(height: 6)
                    Text("新題 \(fresh) ・ 待複習 \(due) ・ 再次挑戰 \(retry)")
                        .appFont(13, relativeTo: .footnote)
                        .monospacedDigit()
                        .opacity(0.9)
                    if isFinalWindow {
                        Label("考前兩週：還沒熟練的錯題每天都會再練一次", systemImage: "calendar.badge.clock")
                            .appFont(12, relativeTo: .caption1)
                            .opacity(0.9)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("今天答對 \(done) 題，目標 \(dailyGoal) 題；新題 \(fresh)、待複習 \(due)、再次挑戰 \(retry)"
                                + (goalMet ? (reviewLeft > 0 ? "；還有 \(reviewLeft) 題要複習" : "；今日目標達成") : ""))
            .accessibilityHint("調整今日練習")
            .accessibilityAddTraits(.isButton)
            Button(action: primaryAction) {
                Text(buttonTitle(done: done, remaining: remaining, due: reviewLeft))
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(PrimaryButtonStyle(height: 52, inverted: true))
            .padding(.top, 4)
            .disabled(bank.questions.isEmpty)
            Button {
                Haptics.selection()
                customRequest = .today()
            } label: {
                HStack(spacing: 4) {
                    Text("自選練習").appFont(15, .medium)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityHint("選科目、年份、單元自己練")
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.heroFill))
    }

    /// 「今日目標 20 題 ・ 距考試 58 天」; without an exam date the tail is a link to set it.
    @ViewBuilder
    private var goalLine: some View {
        let goal = "今日目標 \(dailyGoal) 題"
        if examDate > 0 {
            let days = DateText.daysBetween(.now, Date(timeIntervalSince1970: examDate))
            if days >= 0 {
                (Text("\(goal) ・ 距考試 ") + Text("\(days)").bold() + Text(" 天")).monospacedDigit()
            } else {
                Text("\(goal) ・ 考試日期已過")
            }
        } else {
            HStack(spacing: 0) {
                Text("\(goal) ・ ")
                Button {
                    Haptics.selection()
                    settingsEditsDate = true
                    showSettings = true
                } label: {
                    Text("設定考試日期 ›").bold().underline()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The card's main button: today's queue, an extra round, or a way out once the scope is used up.
    private func primaryAction() {
        let remaining = summary?.plan.queue.count ?? 0
        if remaining == 0 && newExhausted {
            Haptics.selection()
            // A narrower scope cannot help once the whole bank is done.
            if dailyScope.isAll { customRequest = .shortcut(subject: nil, kind: .all) } else { showScope = true }
        } else {
            startSession()
        }
    }

    /// 「調整」: opens 今日練習 (scope, goal and new-question ratio).
    private var adjustChip: some View {
        Button {
            Haptics.selection()
            showPractice = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold))
                Text("調整").appFont(13, .medium, relativeTo: .footnote)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -8)
        .accessibilityLabel("調整今日練習")
    }

    private var dailyScope: PracticeScope {
        _ = dailyScopeRaw
        return ScopeStore.daily()
    }

    /// Every new question of the scope has been answered, so no extra round can be drawn.
    private var newExhausted: Bool {
        guard let s = summary else { return false }
        return s.seenInPool >= s.poolSize
    }

    private func buttonTitle(done: Int, remaining: Int, due: Int) -> String {
        if remaining == 0 && newExhausted { return dailyScope.isAll ? "再練做過的題目" : "換練習範圍" }
        let goalMet = dailyGoal > 0 && done >= dailyGoal
        // Goal met: what is still due, else an extra round.
        if goalMet { return remaining == 0 || due == 0 ? "再練 5 題" : "還有 \(due) 題該複習" }
        if remaining == 0 { return "今日已完成，再做 5 題" }
        if done > 0 { return "繼續今天的題目 ・ 剩 \(max(1, dailyGoal - done)) 題" }
        return "開始今天的 \(dailyGoal) 題"
    }

    private var isFinalWindow: Bool {
        guard examDate > 0 else { return false }
        return ExamDatePolicy(examDate: Date(timeIntervalSince1970: examDate)).isFinalWindow(at: .now)
    }

    // MARK: Actions

    private func refresh() {
        let store = StudyStore(context: context)
        summary = store.todaySummary(bank: bank, includeSpecial: includeSpecial, goal: dailyGoal)
        if let summary { UsageLog.shared.recordToday(TodayUsageStatus(summary: summary)) }
        weekDays = store.weeklyDays(goal: dailyGoal).filter(\.studied).count
        let scope = PointStatsLoader.dailyQuestions(bank: bank, includeSpecial: includeSpecial)
        let stats = PointStatsLoader.ordered(PointStatsLoader.load(context: context, bank: bank, questions: scope), bank: bank)
        let entries = WeakPointRanking.today(stats: stats, snapshot: InsightsStore.shared.snapshot, limit: PointMastery.todayLimit)
        weakPoints = entries.map(\.stat)
        weakReasons = Dictionary(uniqueKeysWithValues: entries.compactMap { e in e.reason.map { (e.stat.point.id, $0) } })
        Task { await ManualAnalysisStore.shared.refreshStatus() }
    }

    /// 「練這科」: that subject's due reviews first, then new questions of the scope, about ten in all. Counts toward
    /// today's goal like the daily flow (`isDaily`); with nothing due and nothing new it opens 自選練習 on the subject.
    private func startSubject(_ subject: String) {
        refresh()
        guard let summary else { return }
        let (queue, retries) = StudyStore(context: context)
            .subjectQueue(subject: subject, summary: summary, bank: bank, includeSpecial: includeSpecial)
        if queue.isEmpty {
            customRequest = .shortcut(subject: subject, kind: .all)
            return
        }
        session = SessionRequest(queue: queue, doneBefore: summary.correctToday, isDaily: true, isSubject: true, retryIDs: retries)
    }

    private func startSession() {
        refresh()
        guard let summary else { return }
        var queue = summary.plan.queue
        if queue.isEmpty {
            queue = StudyStore(context: context).extraNewQuestions(bank: bank, includeSpecial: includeSpecial, count: 5)
        }
        guard !queue.isEmpty else { return }
        session = SessionRequest(queue: queue, doneBefore: summary.correctToday, isDaily: true,
                                 retryIDs: Set(summary.retryIDs))
    }
}
