import SwiftUI
import SwiftData
import Combine

/// Full-screen flow of one mock exam: answering, then the result with review pushed on top.
struct ExamFlowView: View {
    let exam: MockExam
    @State private var finished: Bool

    init(exam: MockExam) {
        self.exam = exam
        _finished = State(initialValue: exam.isFinished)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if finished {
                    ExamResultView(exam: exam, context: .afterExam)
                        .transition(.opacity)
                } else {
                    ExamView(exam: exam) {
                        withAnimation(.easeInOut(duration: 0.3)) { finished = true }
                    }
                    .transition(.opacity)
                }
            }
            .interactivePopEnabled()
        }
    }
}

/// Answering screen: countdown, no correctness shown, flags, collapsible question grid.
struct ExamView: View {
    let exam: MockExam
    let onFinished: () -> Void
    /// Pause-and-leave action; defaults to closing the single-mock cover.
    var onLeave: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.tipExamGridShown) private var tipGridShown = false

    @State private var index = 0
    @State private var usageNavigation = UsageNavigation()
    @State private var forward = true
    @State private var now = Date()
    /// Clock is running since this moment; nil while paused.
    @State private var resumedAt: Date?
    @State private var questionEnteredAt = Date()
    @State private var gridOpen = false
    @State private var askSubmit = false
    @State private var timeUp = false
    @State private var showTip = false
    @State private var panelHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 100

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var questions: [Question] { exam.questionIDs.compactMap { bank.byID[$0] } }
    private var current: Question? { index < questions.count ? questions[index] : nil }
    private var remaining: Double { ExamClock.remaining(stored: exam.elapsed, resumedAt: resumedAt, now: now) }
    private var total: Int { exam.questionIDs.count }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                ForEach(current.map { [$0] } ?? []) { q in
                    ScrollView {
                        questionBody(q)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, panelHeight + 24)
                    }
                    .readableScrollWidth()
                    .contentMargins(.top, topHeight, for: .scrollContent)
                    .contentMargins(.top, topHeight, for: .scrollIndicators)
                    .transition(Motion.questionTransition(reduce: reduceMotion, forward: forward))
                }
                topBar
                    .readHeight($topHeight)
                    .background(Palette.ground.ignoresSafeArea(edges: .top))
                    .zIndex(1)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            bottomPanel
                .readHeight($panelHeight)
                .zIndex(1)

            if timeUp {
                timeUpNotice
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .overlayPreferenceValue(CoachAnchorKey.self) { anchor in
            GeometryReader { geo in
                if showTip, let anchor {
                    CoachSpotlight(rect: geo[anchor], size: geo.size, title: "題號表",
                                   message: "點這裡看全部題號；不確定的題目可標「稍後再看」。",
                                   above: true, onClose: closeTip)
                }
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("確定交卷？", isPresented: $askSubmit) {
            Button("交卷看成績") { submit(auto: false) }
            Button("繼續作答", role: .cancel) {}
        } message: {
            Text(submitMessage)
        }
        .onAppear(perform: start)
        .trackScreen("exam", entry: exam.isFullMockPart ? "fullMock" : "examSetup", navigation: usageNavigation)
        .onDisappear(perform: pause)
        .onReceive(ticker) { t in
            guard resumedAt != nil, !timeUp else { return }
            now = t
            if ExamClock.shouldAutoSubmit(stored: exam.elapsed, resumedAt: resumedAt, now: t) { timeIsUp() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resume() } else { pause() }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { leave() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暫停並離開")
            .accessibilityHint("進度會保存，可在模擬考分頁繼續")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(exam.subject) ・ \(exam.title)")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Text(ExamClock.format(remaining))
                    .appFont(26, .bold, relativeTo: .title1)
                    .monospacedDigit()
                    .foregroundStyle(remaining <= 300 ? Palette.warn : Palette.ink)
                    .accessibilityLabel("剩餘時間 \(Int(remaining) / 60) 分 \(Int(remaining) % 60) 秒")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("交卷") { askSubmit = true }
                .appFont(15, .bold)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent, lineWidth: 1.5))
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: Question

    private func questionBody(_ q: Question) -> some View {
        let flagged = index < exam.flags.count && exam.flags[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                (Text("第 \(index + 1) 題 ").bold() + Text("/ \(total)").foregroundColor(Palette.muted))
                    .appFont(15)
                    .monospacedDigit()
                Spacer(minLength: 4)
                calculatorChip(q)
                Button { toggleFlag() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: flagged ? "flag.fill" : "flag")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.warn)
                        Text("稍後再看").appFont(13, relativeTo: .footnote)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(flagged ? Palette.warnSoft : Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(flagged ? Palette.warn : Palette.chipBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(flagged ? .isSelected : [])
            }
            QuestionStem(question: q, fontSize: 17)
            OrderedOptions(question: q, order: exam.optionOrder(at: index),
                           state: { letter in index < exam.answers.count && exam.answers[index] == letter ? .selected : .idle },
                           tag: { _ in "" }) { letter in
                pick(letter)
            }
        }
    }

    @ViewBuilder
    private func calculatorChip(_ q: Question) -> some View {
        if exam.mode == .wholePaper {
            if q.calculatorAllowed { CalculatorChip(text: "本卷可用計算器") }
        } else {
            CalculatorChip(text: q.calculatorAllowed ? "本題可用計算器" : "本題禁用計算器", allowed: q.calculatorAllowed)
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(Motion.sheetAnimation(reduce: reduceMotion)) { gridOpen.toggle() }
            } label: {
                HStack {
                    Text("題號表").appFont(15, .bold)
                    Spacer()
                    Text("已答 \(exam.answeredCount) ・ 稍後再看 \(exam.flaggedCount)")
                        .appFont(13, relativeTo: .footnote)
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(gridOpen ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .anchorPreference(key: CoachAnchorKey.self, value: .bounds) { $0 }
            .accessibilityValue(gridOpen ? "已展開" : "已收合")
            if gridOpen {
                grid.transition(.opacity)
            }
            HStack(spacing: 10) {
                Button("上一題") { usageNavigation.previousUsed = true; go(to: index - 1) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(index == 0)
                Button(index >= total - 1 ? "交卷" : "下一題") {
                    if index >= total - 1 { askSubmit = true } else {
                        usageNavigation.nextUsed = true
                        go(to: index + 1)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 50))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .readableBarWidth()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(Palette.card)
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                let answered = i < exam.answers.count && !exam.answers[i].isEmpty
                let flagged = i < exam.flags.count && exam.flags[i]
                Button {
                    go(to: i)
                    withAnimation(Motion.sheetAnimation(reduce: reduceMotion)) { gridOpen = false }
                } label: {
                    Text("\(i + 1)")
                        .appFont(12, answered ? .bold : .regular, relativeTo: .caption1)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(answered ? Palette.onAccent : Palette.ink)
                        .background(RoundedRectangle(cornerRadius: 8).fill(answered ? Palette.accent : Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(i == index ? Palette.ink : (answered ? Palette.accent : Palette.chipBorder),
                                          lineWidth: i == index ? 2 : 1))
                        .overlay(alignment: .topTrailing) {
                            if flagged {
                                Circle().fill(Palette.warn).frame(width: 6, height: 6).padding(3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(i + 1) 題\(answered ? "已答" : "未答")\(flagged ? "，稍後再看" : "")\(i == index ? "，目前題目" : "")")
            }
        }
    }

    private var timeUpNotice: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "alarm")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Palette.accent)
                Text("時間到").appFont(20, .bold)
                Text("已自動交卷，正在計分").appFont(15).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
        }
    }

    private var submitMessage: String {
        let unanswered = total - exam.answeredCount
        let flagged = exam.flaggedCount
        var parts: [String] = []
        if unanswered > 0 { parts.append("還有 \(unanswered) 題未作答，未作答的題目不給分。") }
        if flagged > 0 { parts.append("\(flagged) 題標記稍後再看。") }
        let base = parts.isEmpty ? "\(total) 題都已作答。" : parts.joined(separator: "")
        if exam.countsTowardScores { return base }
        let counting = exam.mode == .mistakes
            ? "錯題加強卷不計入成績走勢與及格推估。"
            : "作答未滿 \(exam.countingThreshold) 題，這次不計入成績走勢與及格推估。"
        return base + "\n\n" + counting
    }

    // MARK: Actions

    private func start() {
        #if DEBUG
        DebugLaunch.fillExamAnswers(exam, questions: questions)
        #endif
        index = min(max(0, exam.currentIndex), max(0, total - 1))
        resume()
        if !tipGridShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.2)) { showTip = true }
            }
        }
    }

    private func resume() {
        guard resumedAt == nil, !exam.isSubmitted else { return }
        let t = Date()
        resumedAt = t
        now = t
        questionEnteredAt = t
        if ExamClock.shouldAutoSubmit(stored: exam.elapsed, resumedAt: t, now: t) { timeIsUp() }
    }

    /// Folds the running time into the saved exam and stops the clock.
    private func pause() {
        guard let started = resumedAt, !exam.isSubmitted else { return }
        let t = Date()
        exam.elapsed = min(ExamRules.durationSeconds, ExamClock.elapsed(stored: exam.elapsed, resumedAt: started, now: t))
        addQuestionTime(until: t)
        exam.currentIndex = index
        resumedAt = nil
        try? context.save()
    }

    private func addQuestionTime(until t: Date) {
        guard index < exam.seconds.count else { return }
        exam.seconds[index] += max(0, t.timeIntervalSince(questionEnteredAt))
        questionEnteredAt = t
    }

    private func leave() {
        pause()
        if let onLeave { onLeave() } else { router.activeExam = nil }
    }

    private func pick(_ letter: String) {
        guard index < exam.answers.count else { return }
        Haptics.selection()
        exam.answers[index] = letter
        try? context.save()
    }

    private func toggleFlag() {
        guard index < exam.flags.count else { return }
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.15)) { exam.flags[index].toggle() }
        try? context.save()
    }

    private func go(to target: Int) {
        guard target >= 0, target < total, target != index else { return }
        addQuestionTime(until: Date())
        // Direction is set first so the outgoing question already carries the matching removal transition.
        forward = target > index
        DispatchQueue.main.async {
            withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { index = target }
            exam.currentIndex = target
            try? context.save()
        }
    }

    private func closeTip() {
        tipGridShown = true
        withAnimation(.easeInOut(duration: 0.2)) { showTip = false }
    }

    private func timeIsUp() {
        guard !timeUp else { return }
        withAnimation(.easeInOut(duration: 0.2)) { timeUp = true }
        Haptics.warning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { submit(auto: true) }
    }

    private func submit(auto: Bool) {
        guard !exam.isSubmitted else { return }
        let t = Date()
        let elapsed = auto ? ExamRules.durationSeconds
            : ExamClock.elapsed(stored: exam.elapsed, resumedAt: resumedAt, now: t)
        if resumedAt != nil { addQuestionTime(until: t) }
        resumedAt = nil
        exam.currentIndex = index
        StudyStore(context: context).finish(exam: exam, bank: bank, elapsed: elapsed, auto: auto, now: t)
        onFinished()
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(16)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(Palette.ink)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.chipBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}
