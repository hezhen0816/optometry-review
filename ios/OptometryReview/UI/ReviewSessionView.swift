import SwiftUI
import SwiftData

/// One review session: answers questions in `request.queue` one at a time with one-tap answering.
struct ReviewSessionView: View {
    let request: SessionRequest
    /// Pushed from a list (back button) instead of presented full screen (close button).
    var pushed = false
    /// When pushed: the back button's VoiceOver label, e.g. 「返回錯題本」.
    var backLabel = "返回錯題本"
    /// Usage-log answer source when pushed from a list (`mistakes` or `unit`).
    var listSource = "mistakes"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.tipReasonShown) private var tipReasonShown = false
    @AppStorage(SettingsKey.tipUnsureShown) private var tipUnsureShown = false
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false

    /// Session order; wrong answers return three questions later in daily and 自選練習 sessions.
    @State private var queue: RetryQueue
    @State private var started = false
    @State private var answered = 0
    /// Per-question outcomes of this round, for the completion screen.
    @State private var round = RoundSummary()
    /// Final answer of every question slot of this round, in order (for 檢討這回).
    @State private var roundLog: [RoundAnswer] = []
    @State private var showRoundReview = false
    /// Daily sessions: the next batch for 「再練幾題」, prepared when the round finishes (empty hides the button).
    @State private var moreQueue: [String] = []
    @State private var moreRetryIDs: Set<String> = []
    /// Distinct questions answered correctly today outside mock exams (the daily progress header).
    @State private var correctTodayIDs: Set<String> = []
    /// Distinct questions answered correctly or moved out of review in this session (the 自選練習 progress header).
    @State private var sessionCorrectIDs: Set<String> = []
    /// Chosen letter per slot (position in the queue); kept so the outgoing question keeps its answered look while sliding out.
    @State private var picks: [Int: String] = [:]
    @State private var pendingAnswer: StudyStore.PendingAnswer?
    /// Question shown in the answer sheet and its next-review texts, captured at answer time.
    @State private var sheetQuestion: Question?
    @State private var wrongNextText = ""
    @State private var correctNextText = ""
    @State private var unsureNextText = ""
    @State private var isCorrect = false
    @State private var unsure = false
    @State private var reason: String?
    /// The answer was revealed with 「看解答」 instead of picking an option (scheduled as a wrong answer).
    @State private var revealed = false
    @State private var showSheet = false
    /// False while the answer sheet slides in: rows under it (相關考古題) must not catch a tap meant for the sheet.
    @State private var sheetSettled = false
    @State private var sheetHeight: CGFloat = 0
    @State private var topBarHeight: CGFloat = 52
    @State private var showReasonTip = false
    @State private var showUnsureTip = false
    @State private var finished = false
    @State private var priorAttempts: [Int: Int] = [:]
    /// 「上次 10/6 答錯・背錯」 per slot, from the question's latest attempt.
    @State private var lastNotes: [Int: String] = [:]
    /// Shown option order per slot, drawn when the slot comes up (original order when shuffling is unsafe).
    @State private var orders: [Int: OptionOrder] = [:]
    /// Slots whose question was moved out of review (「移出複習」).
    @State private var parkedSlots: Set<Int> = []
    /// Slots that came up as 「再練一次」, captured when shown so the tag stays during the slide-out.
    @State private var retrySlots: Set<Int> = []
    @State private var confirmPark = false
    @State private var parkToast = false
    @State private var showParked = false
    @State private var relatedPractice: SessionRequest?
    /// 「題目有誤」 sheet and its 「已回報，謝謝」 toast.
    @State private var reportQuestion: Question?
    @State private var reportToast = false
    /// The answer just given took today's correct count to the goal; 「下一題」 then opens the goal page.
    @State private var goalJustReached = false
    /// 「今日目標達成」 page between questions (daily sessions): finish, 檢討這回, or keep reviewing what is left.
    @State private var goalPage = false
    /// After 「繼續複習剩下 N 題」 (or a session that starts past the goal) the top counter shows what is left.
    @State private var pastGoal = false
    /// Queue length when counting down started, for the progress bar.
    @State private var pastGoalTotal = 0
    /// The answer sheet steps aside while the note or a follow-up question is being edited.
    @State private var editingNote = false
    /// Slots whose AI panel is open.
    @State private var aiOpen: Set<Int> = []
    @State private var aiUsage = AIUsageSessions()
    @State private var aiTriggers: [Int: String] = [:]
    @State private var usageNavigation = UsageNavigation()
    /// Bumped by the sheet's 「AI 解析」 to scroll the panel into view.
    @State private var aiScrollRequest = 0
    private static let aiAnchor = "ai-panel"
    /// Wide (iPad landscape) layout is showing; set from the layout's width. The AI panel then opens by itself.
    @State private var isWide = false
    /// Width of the question area (the window, minus nothing): the one-row iPad answer bar needs room for its four chips.
    @State private var layoutWidth: CGFloat = 0

    init(request: SessionRequest, pushed: Bool = false, backLabel: String = "返回錯題本", listSource: String = "mistakes") {
        self.request = request
        self.pushed = pushed
        self.backLabel = backLabel
        self.listSource = listSource
        _queue = State(initialValue: RetryQueue(ids: request.queue, retryIDs: request.retryIDs))
    }

    /// Original letter picked for a wrong answer in this slot; nil for right answers and 「看解答」.
    private func wrongChoice(slot: Int, question q: Question) -> String? {
        guard let letter = picks[slot], Question.letters.contains(letter),
              !Grading.isCorrect(chosen: letter, question: q) else { return nil }
        return letter
    }

    private func aiOpenBinding(_ slot: Int) -> Binding<Bool> {
        Binding(get: { aiOpen.contains(slot) }, set: { open in
            if open {
                aiTriggers[slot] = "manual"
                aiOpen.insert(slot)
            } else { aiOpen.remove(slot) }
        })
    }

    private func openAI(_ q: Question, trigger: String = "manual") {
        let slot = queue.index
        if !aiOpen.contains(slot) {
            aiTriggers[slot] = trigger
            AIExplainer.shared?.clearError(q.id)
            withAnimation(.easeInOut(duration: 0.2)) { _ = aiOpen.insert(slot) }
        }
        // Wait one layout pass so the panel exists before scrolling to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { aiScrollRequest += 1 }
    }

    /// Opens the AI panel right after an answer: always in the wide layout, on a wrong answer or 「看解答」 in the narrow one.
    /// Runs once per slot (submit is guarded), only when the panel would render.
    private func autoOpenAI(_ q: Question, slot: Int, wrong: Bool) {
        guard AIExplainer.shared != nil, AIQuestionPayload.make(q, bank: bank) != nil else { return }
        if isWide {
            AIExplainer.shared?.clearError(q.id)
            aiTriggers[slot] = "auto"
            aiOpen.insert(slot)
        } else if wrong {
            openAI(q, trigger: "auto")
        }
    }

    private var store: StudyStore { StudyStore(context: context) }
    private var current: Question? { queue.currentID.flatMap { bank.byID[$0] } }

    /// One occurrence of a question in the session; a retry is a new slot of the same question.
    private struct Slot: Identifiable {
        let id: Int
        let question: Question
    }

    private var currentSlot: Slot? { current.map { Slot(id: queue.index, question: $0) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The question scrolls under the top bar, which carries the ground color so passing text stays hidden.
            ZStack(alignment: .top) {
                if finished {
                    completion
                        .padding(.top, topBarHeight)
                        .transition(Motion.questionTransition(reduce: reduceMotion))
                } else if goalPage {
                    goalReached
                        .padding(.top, topBarHeight)
                        .transition(Motion.questionTransition(reduce: reduceMotion))
                } else {
                    ForEach(currentSlot.map { [$0] } ?? []) { slot in
                        GeometryReader { geo in
                            ScrollViewReader { proxy in
                                Group {
                                    if Layout.isWideAnswerLayout(geo.size) {
                                        wideLayout(slot)
                                    } else {
                                        narrowLayout(slot)
                                    }
                                }
                                .onChange(of: aiScrollRequest) {
                                    if reduceMotion {
                                        proxy.scrollTo(Self.aiAnchor, anchor: .top)
                                    } else {
                                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(Self.aiAnchor, anchor: .top) }
                                    }
                                }
                                .onAppear { isWide = Layout.isWideAnswerLayout(geo.size); layoutWidth = geo.size.width }
                                .onChange(of: geo.size) { isWide = Layout.isWideAnswerLayout(geo.size); layoutWidth = geo.size.width }
                            }
                        }
                        .trackScreen("question")
                        .transition(Motion.questionTransition(reduce: reduceMotion))
                    }
                }
                topBar
                    .readHeight($topBarHeight)
                    .background(Palette.ground.ignoresSafeArea(edges: .top))
                    .zIndex(1)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if showSheet, !editingNote, let q = sheetQuestion {
                answerSheet(q)
                    .readHeight($sheetHeight)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .ignoresSafeArea(.keyboard)
                    .zIndex(1)
            }
            if reportToast {
                Toast(text: "已回報，謝謝")
                    .padding(.horizontal, 20)
                    .padding(.bottom, (showSheet && !editingNote ? sheetHeight : 0) + 12)
                    .transition(.opacity)
                    .zIndex(2)
            }
            if parkToast {
                Toast(text: "已移出複習", actionTitle: "查看") { showParked = true }
                    .padding(.horizontal, 20)
                    .padding(.bottom, (showSheet && !editingNote ? sheetHeight : 0) + 12)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .overlayPreferenceValue(CoachAnchorKey.self) { anchor in
            GeometryReader { geo in
                if showUnsureTip, let anchor {
                    CoachSpotlight(rect: geo[anchor], size: geo.size, title: "猜對的也要標",
                                   message: "猜對的勾這裡，會早點再練。", above: true, onClose: closeUnsureTip)
                }
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // A pushed session in progress is left with its own back button only, never by a stray edge swipe.
        .blocksInteractivePop(pushed)
        .onAppear(perform: start)
        .onDisappear {
            commitPending()
            aiUsage.finishAll()
        }
        .onChange(of: queue.index) { old, _ in aiUsage.finish(String(old)) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { commitPending() }
        }
        .trackScreen("review", answerSource: pushed ? listSource : request.isCustom ? "custom"
                     : request.isPractice ? "practice" : request.isSubject ? "subject" : request.isDaily ? "today" : "extra",
                     entry: pushed ? listSource : request.isPaper ? "paper" : request.isCustom ? "customPractice"
                     : request.isPractice ? "practice" : "today", navigation: usageNavigation)
        .sheet(item: $relatedPractice) { req in
            ReviewSessionView(request: req)
        }
        .sheet(item: $reportQuestion) { q in
            QuestionReportSheet(question: q) { showReportToast($reportToast) }
        }
        .fullScreenCover(isPresented: $showRoundReview) {
            NavigationStack {
                RoundReviewView(answers: RoundReview.firstAnswers(roundLog)) { showRoundReview = false }
                    .interactivePopEnabled()
            }
        }
        .sheet(isPresented: $showParked) {
            NavigationStack {
                ParkedMistakesView(onClose: { showParked = false })
                    .interactivePopEnabled()
            }
        }
        .confirmationDialog("移出複習", isPresented: $confirmPark, titleVisibility: .visible) {
            Button("移出複習", role: .destructive, action: park)
            Button("取消", role: .cancel) {}
        } message: {
            if SettingsKey.tipPending(SettingsKey.noteRetiredShown) {
                Text("這題不會再出現在複習，可在錯題本「不用再練」移回。")
            }
        }
        .onChange(of: confirmPark) { _, now in
            // Shown once: the flag is set when the dialog closes.
            if !now { SettingsKey.markTipShown(SettingsKey.noteRetiredShown) }
        }
    }

    // MARK: Question layouts

    private var scrollBottomPadding: CGFloat { showSheet && !editingNote ? sheetHeight + 16 : 24 }

    private func questionContent(_ slot: Slot) -> some View {
        QuestionContent(question: slot.question, order: orders[slot.id] ?? .original, chosen: picks[slot.id],
                        priorAttempts: priorAttempts[slot.id] ?? 0, lastNote: lastNotes[slot.id],
                        isRetry: retrySlots.contains(slot.id),
                        onAnswer: answer,
                        onReveal: reveal)
    }

    private func relatedList(_ q: Question) -> some View {
        RelatedQuestionsList(question: q, onOpen: openRelated)
            .allowsHitTesting(sheetSettled)
            .transition(.opacity)
    }

    /// Narrow: the 「AI 解析」 button lives in the answer sheet (a wrong answer opens the panel itself); the panel shows here.
    private func aiSection(_ slot: Slot, showsTrigger: Bool = false) -> some View {
        AIExplainSection(question: slot.question, order: orders[slot.id] ?? .original,
                         isOpen: aiOpenBinding(slot.id),
                         wrongChoice: wrongChoice(slot: slot.id, question: slot.question),
                         showsTrigger: showsTrigger, trigger: aiTriggers[slot.id] ?? "manual", usage: aiUsage.session(String(slot.id)),
                         onInputFocus: { f in
                             withAnimation(Motion.sheetAnimation(reduce: reduceMotion)) { editingNote = f }
                         })
            .id(Self.aiAnchor)
    }

    private func detailExtras(_ q: Question) -> some View {
        QuestionDetailExtras(question: q, showRelated: false,
                             onNoteFocus: { f in
                                 withAnimation(Motion.sheetAnimation(reduce: reduceMotion)) { editingNote = f }
                             },
                             onOpenRelated: openRelated)
            .transition(.opacity)
    }

    /// Phone and iPad portrait: one column, AI 解析 right under the question, 相關考古題 below it.
    private func narrowLayout(_ slot: Slot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                questionContent(slot)
                if picks[slot.id] != nil {
                    aiSection(slot)
                    relatedList(slot.question)
                    detailExtras(slot.question)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, scrollBottomPadding)
        }
        .readableScrollWidth()
        .contentMargins(.top, topBarHeight, for: .scrollContent)
        .contentMargins(.top, topBarHeight, for: .scrollIndicators)
        .scrollDismissesKeyboard(.interactively)
    }

    /// iPad landscape: question, 相關考古題 and notes on the left; AI 解析 in a 500pt right column (as in `AIPracticeView`).
    private func wideLayout(_ slot: Slot) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    questionContent(slot)
                    if picks[slot.id] != nil {
                        relatedList(slot.question)
                        detailExtras(slot.question)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, scrollBottomPadding)
            }
            .contentMargins(.top, topBarHeight, for: .scrollContent)
            .contentMargins(.top, topBarHeight, for: .scrollIndicators)
            .scrollDismissesKeyboard(.interactively)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if picks[slot.id] != nil {
                        // Opens by itself after answering; the inline trigger reopens it once collapsed.
                        aiSection(slot, showsTrigger: true)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, scrollBottomPadding)
            }
            .contentMargins(.top, topBarHeight, for: .scrollContent)
            .contentMargins(.top, topBarHeight, for: .scrollIndicators)
            .scrollDismissesKeyboard(.interactively)
            .frame(width: 500)
        }
        .padding(.horizontal, 28)
    }

    // MARK: Top bar

    /// Daily: today's distinct correct answers against the goal; 自選練習: questions finished; others: position.
    private var progressNumbers: (shown: String, fraction: Double, spoken: String) {
        if request.isDaily, pastGoal {
            let left = queue.remainingIDs.count
            let fraction = pastGoalTotal > 0 ? max(0, min(1, 1 - Double(left) / Double(pastGoalTotal))) : 0
            return ("剩 \(left) 題", fraction, "還剩 \(left) 題")
        }
        if request.isDaily {
            let n = correctTodayIDs.count
            return ("\(n) / \(dailyGoal)", dailyGoal > 0 ? min(1, Double(n) / Double(dailyGoal)) : 0,
                    "今天答對 \(n) 題，目標 \(dailyGoal) 題")
        }
        if request.isCustom {
            let total = Set(queue.order).count
            let n = sessionCorrectIDs.count
            return ("\(n) / \(total)", total > 0 ? Double(n) / Double(total) : 0, "完成 \(n) / \(total) 題")
        }
        let total = queue.order.count
        let position = min(total, queue.index + 1)
        return ("\(position) / \(total)", total > 0 ? Double(answered) / Double(total) : 0, "\(answered) / \(total)")
    }

    private var topBar: some View {
        let numbers = progressNumbers
        return HStack(spacing: 12) {
            if pushed {
                BackButton(label: backLabel) {
                    commitPending()
                    dismiss()
                }
                .frame(maxWidth: 160, alignment: .leading)
                .layoutPriority(1)
                .padding(.leading, -10)
            } else {
                Button {
                    commitPending()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .padding(.leading, -10)
                .accessibilityLabel(request.isPractice || request.isCustom ? "結束練習" : "結束複習")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.border)
                    Capsule().fill(Palette.accent).frame(width: geo.size.width * numbers.fraction)
                        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.3), value: numbers.fraction)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("進度")
            .accessibilityValue(numbers.spoken)
            Text(numbers.shown)
                .appFont(14, relativeTo: .subheadline).monospacedDigit()
                .foregroundStyle(Palette.muted)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            // Shown from the start (not only after answering) so the progress bar never resizes mid-question.
            if let q = current, !finished, !goalPage {
                HStack(spacing: 0) {
                    BookmarkButton(question: q)
                    Menu {
                        // Parking saves the answer first, so it waits until the question is answered.
                        if picks[queue.index] != nil, !parkedSlots.contains(queue.index) {
                            Button(role: .destructive) {
                                confirmPark = true
                            } label: {
                                Label("移出複習", systemImage: "minus.circle")
                            }
                        }
                        QuestionReportMenuItem(question: q) { reportQuestion = q }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")
                }
                .padding(.trailing, -10)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: Sheet

    @ViewBuilder
    private func answerSheet(_ q: Question) -> some View {
        let compact = compactSheet
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                // iPad: the whole bar is one row (header, mistake reasons, next button); the open AI panel needs no second trigger.
                if !isCorrect, showReasonTip { reasonTip.transition(.opacity) }
                HStack(alignment: .center, spacing: 16) {
                    if isCorrect {
                        rightHeader(q)
                    } else {
                        wrongTitle(stacked: true).frame(minWidth: 150, maxWidth: 230, alignment: .leading)
                        reasonChips(minChipWidth: 76)
                    }
                    if !isWide, !aiOpen.contains(queue.index) { AIExplainButton(question: q, fullWidth: false) { openAI(q) } }
                    nextButton.frame(width: 140)
                }
            } else {
                if isCorrect {
                    rightHeader(q)
                } else {
                    wrongHeader
                }
                HStack(spacing: 10) {
                    // Wide layout opens the panel by itself and keeps a trigger in the right column.
                    if !isWide { AIExplainButton(question: q, fullWidth: false) { openAI(q) } }
                    nextButton
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .readableBarWidth()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(Palette.card)
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// iPad windows at least `oneRowBarMinWidth` wide (portrait and landscape): the answer bar is a single row, so it covers as little of the page as possible.
    private var compactSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && layoutWidth >= Self.oneRowBarMinWidth
    }
    /// Narrower windows (split view, Slide Over, a 2/3 split) keep the phone's two-row bar; at 760pt the four chips get about 80pt each.
    private static let oneRowBarMinWidth: CGFloat = 760

    private var nextButton: some View {
        Button(isLast ? "完成" : "下一題") {
            if !isLast { usageNavigation.nextUsed = true }
            advance()
        }
        .buttonStyle(PrimaryButtonStyle(height: 52))
    }

    private var wrongHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            wrongTitle(stacked: false)
            if showReasonTip {
                reasonTip.transition(.opacity)
            }
            reasonChips(minChipWidth: 0)
        }
    }

    @ViewBuilder
    private func wrongTitle(stacked: Bool) -> some View {
        if stacked {
            // One-row bar: the title column is narrow, so the next-review line sits under the title and wraps.
            VStack(alignment: .leading, spacing: 4) {
                (Text("這題錯在哪？").bold() + Text("（可略過）").font(.system(size: 13)).foregroundColor(Palette.muted))
                    .appFont(17).fixedSize(horizontal: false, vertical: true)
                if parkedSlots.contains(queue.index) || !revealed {
                    Text(parkedSlots.contains(queue.index) ? "不用再練" : wrongNextText)
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if revealed && !parkedSlots.contains(queue.index) {
                    Text("看解答（算答錯）").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    (Text("這題錯在哪？").bold() + Text("（可略過）").font(.system(size: 13)).foregroundColor(Palette.muted))
                        .appFont(17)
                    Spacer(minLength: 8)
                    if parkedSlots.contains(queue.index) || !revealed {
                        Text(parkedSlots.contains(queue.index) ? "不用再練" : wrongNextText)
                            .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    }
                }
                // 「看解答」 is scheduled as a miss; say so on its own line instead of the short trailing text.
                if revealed && !parkedSlots.contains(queue.index) {
                    Text("看解答（算答錯）")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        }
    }

    private func reasonChips(minChipWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Plain HStack, not LazyVGrid: lazy children are inserted on their own and skip the sheet's slide-in.
            HStack(spacing: 8) {
                ForEach(MistakeReason.all, id: \.self) { label in
                    let on = reason == label
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) { reason = on ? nil : label }
                    } label: {
                        Text(label).appFont(14, .medium, relativeTo: .subheadline)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(minWidth: minChipWidth, maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(on ? Palette.onAccent : Palette.ink)
                            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accent : Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Palette.accent : Palette.border, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    /// First wrong answer: a small tip above the reason chips, inside the sheet so the options stay visible.
    private var reasonTip: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("標了錯因，之後看得出自己最常錯在哪。")
                .appFont(14, relativeTo: .subheadline)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: closeTip) {
                Text("知道了").appFont(14, .bold)
                    .foregroundStyle(Palette.onCoachPill)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Palette.coach)
                .overlay(alignment: .bottomLeading) {
                    Rectangle().fill(Palette.coach)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(45))
                        .offset(x: 36, y: 6)
                }
        )
        .padding(.bottom, -4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("提示：標了錯因，之後看得出自己最常錯在哪")
        .accessibilityAction(named: "知道了", closeTip)
    }

    /// 「答對了」 with its next-review line; 「猜的」 sits on the trailing side of the same row.
    private func rightHeader(_ q: Question) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("答對了").appFont(17, .bold)
                Text(parkedSlots.contains(queue.index) ? "不用再練" : (unsure ? unsureNextText : correctNextText))
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !queue.isRetry {
                guessToggle
            }
        }
    }

    private var guessToggle: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { unsure.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: unsure ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(unsure ? Palette.accent : Palette.muted)
                Text("猜的").appFont(14, relativeTo: .subheadline)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -8)
        .anchorPreference(key: CoachAnchorKey.self, value: .bounds) { $0 }
        .accessibilityLabel("猜的")
        .accessibilityHint("猜對的勾這裡，會早點再練")
        .accessibilityAddTraits(unsure ? .isSelected : [])
    }

    /// 「下次複習：明天」 from the FSRS preview of a proposed answer.
    private func nextText(_ q: Question, correct: Bool, unsure: Bool, now: Date) -> String {
        let next = store.preview(questionID: q.id, correct: correct, unsure: unsure, now: now)
        // Only a question moved to 不用再練 is unscheduled after an answer.
        if !next.isScheduled { return "已移出複習" }
        guard let days = next.daysUntilNextReview else { return "考前不再出現" }
        // 確認題: answered correctly without 猜的 and never wrong; not a mistake.
        if next.isConfirmation { return "下次確認：\(DateText.nextReview(days: days))" }
        return "下次複習：\(DateText.nextReview(days: days))"
    }

    /// No question follows: nothing remains after this one, and a wrong answer here will not come back.
    private var isLast: Bool {
        let returns = request.retriesWrong && !isCorrect && !parkedSlots.contains(queue.index)
        return queue.remainingIDs.count <= 1 && !returns
    }

    // MARK: Completion

    private var completion: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)
            Text(goalLeft == 0 ? "今日目標達成" : "這一輪完成了")
                .headingFont(28)
            VStack(spacing: 6) {
                ForEach(round.lines(retries: request.retriesWrong), id: \.self) { line in
                    Text(line).appFont(17).foregroundStyle(Palette.muted)
                }
                if let left = goalLeft, left > 0 {
                    Text("今天還差 \(left) 題達標").appFont(17, .bold).foregroundStyle(Palette.ink)
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            let groups = reviewGroups
            weakPointsOrAllRight(groups)
            Spacer()
            let canReview = !groups.isEmpty && (AIExplainer.shared?.isConfigured ?? false)
            if let left = goalLeft, left > 0, !moreQueue.isEmpty {
                Button("再練幾題", action: practiceMore)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 4)
                if canReview { reviewButton }
                Button(completionTitle) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, 4)
            } else {
                Button(completionTitle) { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 4)
                if canReview { reviewButton }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .readableBarWidth()
    }

    /// 「這輪錯在這些考點」, or the all-right note when no answer of the round was wrong or guessed.
    @ViewBuilder
    private func weakPointsOrAllRight(_ groups: [ReviewGroup]) -> some View {
        if !groups.isEmpty {
            SessionWeakPointsCard(groups: groups)
                .padding(.top, 4)
        } else if round.practiced > 0 {
            Text("這輪全對，沒有要檢討的").appFont(15).foregroundStyle(Palette.muted)
                .padding(.top, 4)
        }
    }

    /// 「今日目標達成」: shown when 「下一題」 follows the answer that reached the goal and questions remain.
    private var goalReached: some View {
        let left = queue.remainingIDs.count
        let groups = reviewGroups
        let canReview = !groups.isEmpty && (AIExplainer.shared?.isConfigured ?? false)
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)
            Text("今日目標達成").headingFont(28)
            VStack(spacing: 6) {
                Text("今天答對 \(correctTodayIDs.count) 題").appFont(17).foregroundStyle(Palette.muted)
                ForEach(round.lines(retries: request.retriesWrong), id: \.self) { line in
                    Text(line).appFont(17).foregroundStyle(Palette.muted)
                }
            }
            .multilineTextAlignment(.center)
            weakPointsOrAllRight(groups)
            Spacer()
            Button("繼續複習剩下 \(left) 題", action: continuePastGoal)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 4)
            if canReview { reviewButton }
            Button(completionTitle) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .readableBarWidth()
    }

    private func continuePastGoal() {
        Haptics.selection()
        pastGoalTotal = queue.remainingIDs.count
        pastGoal = true
        withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { goalPage = false }
    }

    private var reviewButton: some View {
        Button("檢討這回") {
            Haptics.selection()
            showRoundReview = true
        }
        .buttonStyle(SecondaryButtonStyle())
        .padding(.horizontal, 4)
    }

    /// Wrong or guessed questions of this round by 考點 (the first answer of each question counts).
    private var reviewGroups: [ReviewGroup] {
        RoundReview.group(RoundReview.flagged(RoundReview.firstAnswers(roundLog)),
                          pointsOfQuestion: bank.learning.pointsOfQuestion)
    }

    /// Daily sessions only: questions still needed today, matching the top bar's count (nil without a goal).
    private var goalLeft: Int? {
        request.isDaily ? RoundSummary.goalLeft(correctToday: correctTodayIDs.count, goal: dailyGoal) : nil
    }

    /// Prepares 「再練幾題」: what is left of today's plan, else a few new questions.
    private func prepareMore() {
        guard request.isDaily, let left = goalLeft, left > 0 else { moreQueue = []; return }
        let summary = store.todaySummary(bank: bank, includeSpecial: includeSpecial, goal: dailyGoal)
        var ids = summary.plan.queue.filter { bank.byID[$0] != nil }
        if ids.isEmpty {
            ids = store.extraNewQuestions(bank: bank, includeSpecial: includeSpecial, count: max(5, left))
        }
        moreQueue = ids
        moreRetryIDs = Set(summary.retryIDs)
    }

    /// 「再練幾題」: starts another round of today's practice on this screen.
    private func practiceMore() {
        let ids = moreQueue
        guard !ids.isEmpty else { return }
        picks = [:]
        orders = [:]
        priorAttempts = [:]
        lastNotes = [:]
        parkedSlots = []
        retrySlots = []
        aiUsage.finishAll()
        aiOpen = []
        sessionCorrectIDs = []
        answered = 0
        goalJustReached = false
        goalPage = false
        round = RoundSummary()
        roundLog = []
        pendingAnswer = nil
        moreQueue = []
        withAnimation(Motion.questionAnimation(reduce: reduceMotion)) {
            queue = RetryQueue(ids: ids, retryIDs: moreRetryIDs)
            finished = false
        }
        loadPrior()
    }

    private var completionTitle: String {
        if pushed { return "回到" + BackButton.title(backLabel) }
        if request.isPaper { return "回到試卷" }
        return request.isPractice || request.isCustom ? "完成" : "回到今日"
    }

    // MARK: Actions

    private func start() {
        guard !started else { return }
        started = true
        // Questions missing from the bank are dropped up front so the queue never stalls on them.
        queue = RetryQueue(ids: request.queue.filter { bank.byID[$0] != nil }, retryIDs: request.retryIDs)
        if request.isDaily {
            let since = Calendar.current.startOfDay(for: .now)
            correctTodayIDs = Set(store.attempts(since: since)
                .filter { $0.correct && $0.source != AttemptRecord.examSource }.map(\.questionID))
            // Already past the goal when the session opens: count down from the start, no goal page.
            if dailyGoal > 0, correctTodayIDs.count >= dailyGoal {
                pastGoal = true
                pastGoalTotal = queue.remainingIDs.count
            }
        }
        loadPrior()
    }

    private func openRelated(_ q: Question) {
        relatedPractice = SessionRequest(queue: [q.id], doneBefore: 0, isDaily: false, isPractice: true)
    }

    private func loadPrior() {
        let slot = queue.index
        guard let q = current, priorAttempts[slot] == nil else { return }
        var rng = SystemRandomNumberGenerator()
        orders[slot] = OptionOrder(shown: OptionShuffle.order(for: q, using: &rng))
        if queue.isRetry { retrySlots.insert(slot) }
        let record = store.record(for: q.id)
        priorAttempts[slot] = record.map { max(1, ($0.attempts ?? []).count) } ?? 0
        lastNotes[slot] = record.flatMap { Self.lastNote(attempts: $0.attempts ?? []) }
    }

    /// The latest miss: 「上次 10/6 答錯・背錯」, 「上次 10/6 看解答」 or 「上次 10/6 猜的」; nil when never missed or guessed.
    static func lastNote(attempts: [AttemptRecord]) -> String? {
        guard let last = attempts.filter({ !$0.correct || $0.unsure }).max(by: { $0.timestamp < $1.timestamp })
        else { return nil }
        let day = "上次 \(DateText.monthDay.string(from: last.timestamp))"
        if last.correct { return "\(day) 猜的" }
        let what = last.chosen.isEmpty && last.source != AttemptRecord.examSource ? "看解答" : "答錯"
        return [day + " " + what, last.reason].compactMap { $0 }.joined(separator: "・")
    }

    /// 「看解答」: reveals the answer and schedules the question as a wrong answer; the reason stays empty (skippable).
    func reveal() {
        submit(Self.revealedChoice, revealed: true)
    }

    /// Stored as the chosen letter of a revealed answer: no option was picked.
    private static let revealedChoice = ""

    func answer(_ letter: String) {
        submit(letter, revealed: false)
    }

    private func submit(_ letter: String, revealed: Bool) {
        let slot = queue.index
        guard let q = current, picks[slot] == nil else { return }
        let now = Date.now
        let retry = queue.isRetry
        pendingAnswer = store.pendingAnswer(for: q.id, now: now)
        Haptics.answer()
        self.revealed = revealed
        reason = nil
        unsure = false
        isCorrect = !revealed && Grading.isCorrect(chosen: letter, question: q)
        sheetQuestion = q
        wrongNextText = request.retriesWrong ? "隔 3 題會再出一次" : nextText(q, correct: false, unsure: false, now: now)
        correctNextText = retry ? "完成，明天再複習" : nextText(q, correct: true, unsure: false, now: now)
        unsureNextText = retry ? correctNextText : nextText(q, correct: true, unsure: true, now: now)
        // Not animated as a whole: option rows animate only their colors, so text never re-wraps mid-animation.
        picks[slot] = letter
        answered += 1
        round.record(q.id, correct: isCorrect)
        if isCorrect {
            let before = correctTodayIDs.count
            withAnimation(.easeInOut(duration: 0.2)) {
                correctTodayIDs.insert(q.id)
                sessionCorrectIDs.insert(q.id)
            }
            if request.isDaily, RoundSummary.reachedGoal(before: before, after: correctTodayIDs.count, goal: dailyGoal) {
                goalJustReached = true
            }
        }
        autoOpenAI(q, slot: slot, wrong: !isCorrect)
        sheetSettled = false
        withAnimation(Motion.sheetAnimation(reduce: reduceMotion), completionCriteria: .logicallyComplete) {
            showSheet = true
        } completion: {
            sheetSettled = true
        }
        if !isCorrect && !tipReasonShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeInOut(duration: 0.2)) { showReasonTip = true }
            }
        }
        if isCorrect && !retry && !tipUnsureShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.2)) { showUnsureTip = true }
            }
        }
    }

    private func closeUnsureTip() {
        tipUnsureShown = true
        withAnimation(.easeInOut(duration: 0.2)) { showUnsureTip = false }
    }

    private func closeTip() {
        tipReasonShown = true
        withAnimation(.easeInOut(duration: 0.2)) { showReasonTip = false }
    }

    /// Repeated saves revise the same attempt from the option-tap baseline.
    private func commitPending() {
        guard let q = current, let letter = picks[queue.index], let pendingAnswer else { return }
        let retry = queue.isRetry
        store.commit(question: q, chosen: letter, correct: isCorrect, unsure: isCorrect && unsure && !retry,
                     reason: isCorrect ? nil : reason, revealed: revealed,
                     pending: pendingAnswer, retry: retry, now: pendingAnswer.timestamp)
    }

    /// 「移出複習」: saves the answer first (parking needs its record), then parks the question.
    private func park() {
        guard let q = current else { return }
        commitPending()
        guard store.park(questionID: q.id) else { return }
        Haptics.selection()
        parkedSlots.insert(queue.index)
        // A parked question never comes back, so it counts as finished in the 自選練習 header.
        withAnimation(.easeInOut(duration: 0.2)) { _ = sessionCorrectIDs.insert(q.id) }
        // Stays until 下一題 so 「查看」 remains reachable.
        withAnimation(.easeInOut(duration: 0.2)) { parkToast = true }
    }

    private func advance() {
        if showReasonTip { closeTip() }
        if showUnsureTip { closeUnsureTip() }
        commitPending()
        pendingAnswer = nil
        guard let q = current else { return }
        if let letter = picks[queue.index] {
            roundLog.append(RoundAnswer(qid: q.id, chosen: letter, correct: isCorrect,
                                        unsure: isCorrect && unsure && !queue.isRetry))
        }
        // Parked questions and sessions without retries never come back.
        let done = !request.retriesWrong || isCorrect || parkedSlots.contains(queue.index)
        withAnimation(Motion.sheetAnimation(reduce: reduceMotion)) {
            showSheet = false
            parkToast = false
        }
        withAnimation(Motion.questionAnimation(reduce: reduceMotion)) {
            queue.answer(id: q.id, correct: done)
            if queue.currentID == nil { finished = true }
            else if goalJustReached, !pastGoal { goalPage = true }
        }
        goalJustReached = false
        if finished { prepareMore() }
        if pushed && request.queue.count == 1 {
            dismiss()
            return
        }
        loadPrior()
    }
}

// MARK: - Question content

private struct QuestionContent: View {
    let question: Question
    let order: OptionOrder
    /// Original letter chosen; nil before answering.
    let chosen: String?
    let priorAttempts: Int
    /// 「上次 10/6 答錯・背錯」, shown next to the review count.
    var lastNote: String? = nil
    /// Answered wrong earlier in this session or today: 「再練一次」.
    var isRetry = false
    let onAnswer: (String) -> Void
    /// 「看解答」 (review and practice only; mock exams have their own screen).
    let onReveal: () -> Void

    private var presentation: AnswerPresentation { AnswerPresentation(question: question, order: order, chosen: chosen) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Chip(text: question.subject, kind: .subject)
                Chip(text: question.sourceLabel)
                if isRetry {
                    Label("再練一次", systemImage: "arrow.triangle.2.circlepath")
                        .appFont(12, .bold, relativeTo: .caption1)
                        .foregroundStyle(Palette.warn)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.warnSoft))
                        .overlay(Capsule().strokeBorder(Palette.warn, lineWidth: 1))
                        .labelStyle(TightLabelStyle())
                } else if priorAttempts > 0 {
                    Chip(text: "第 \(priorAttempts) 次複習")
                    if let lastNote {
                        Text(lastNote)
                            .appFont(12, relativeTo: .caption1)
                            .foregroundStyle(Palette.muted)
                            .padding(.vertical, 4)
                    }
                } else {
                    Chip(text: "新題")
                }
                if question.corrected || question.allCredit {
                    Chip(text: "有更正答案", kind: .notice)
                }
            }
            QuestionStem(question: question)
            OrderedOptions(question: question, order: order, state: presentation.state, tag: presentation.tag) { letter in
                onAnswer(letter)
            }
            .allowsHitTesting(chosen == nil)
            if let text = presentation.correctionText {
                // Space is reserved before answering so nothing below shifts when it appears.
                Text(text)
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice))
                    .animation(Motion.answerReveal) { $0.opacity(chosen == nil ? 0 : 1) }
                    .accessibilityHidden(chosen == nil)
            }
            Text(order.isOriginal ? "答案依考選部標準答案；有更正答案時以更正為準"
                 : "選項順序已打亂")
                .appFont(12, relativeTo: .caption1)
                .foregroundStyle(Palette.muted)
            if chosen == nil {
                // Last in the column so nothing above it moves when it goes away after answering.
                Button {
                    onReveal()
                } label: {
                    Text("看解答")
                        .appFont(15, .bold)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityHint("算答錯，之後會再練")
            }
        }
    }
}

/// Icon and title with a small gap, for compact tags.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}
