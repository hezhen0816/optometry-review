import SwiftUI
import SwiftData

/// Animates an integer from its previous value (count-up).
private struct CountingText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}

private struct ReviewTarget: Hashable {
    let index: Int
    let onlyWrong: Bool
}

/// Single-subject mock result. Never says 及格 for one subject: the 60-point line is only a reference.
struct ExamResultView: View {
    enum Context { case afterExam, history }

    let exam: MockExam
    let context: Context

    @Environment(\.questionBank) private var bank
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router

    @State private var shownScore: Double = 0
    @State private var settled = false
    @State private var review: ReviewTarget?

    private var questions: [Question] { exam.questionIDs.compactMap { bank.byID[$0] } }
    private var result: ExamScore { ExamScoring.score(questions: questions, answers: exam.answers) }
    private var missedCount: Int { result.wrong + result.unanswered }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    scoreCard
                    gridSection
                }
                .padding(.horizontal, 20)
                .padding(.top, context == .history ? 0 : 20)
                .padding(.bottom, 16)
            }
            .readableScrollWidth()
            buttons
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $review) { target in
            ExamReviewView(exam: exam, startIndex: target.index, onlyWrongInitially: target.onlyWrong)
        }
        .onAppear(perform: countUp)
        .trackScreen("examResult")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if context == .history {
                BackButton(label: "返回考試紀錄") { dismiss() }
                    .padding(.leading, -10)
            }
            Text("\(exam.subject) ・ \(exam.title)")
                .appFont(14, relativeTo: .subheadline)
                .foregroundStyle(Palette.muted)
            Text("模擬考成績").headingFont(28)
        }
    }

    private var scoreCard: some View {
        let score = exam.score
        let above = score >= ExamRules.referenceLine
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The final value's width is reserved so the counter never shifts the row while counting.
                    ZStack(alignment: .trailing) {
                        Text("\(score)").hidden()
                        CountingText(value: shownScore)
                            .foregroundStyle(Palette.accent)
                    }
                    .appFont(64, .bold, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                    Text("/ 100 分").appFont(18).foregroundStyle(Palette.muted)
                }
                .fixedSize()
                Spacer(minLength: 8)
                Text(score == ExamRules.referenceLine ? "達到 60 分參考線" : (above ? "高於 60 分參考線" : "低於 60 分參考線"))
                    .appFont(14, .bold, relativeTo: .subheadline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(above ? Palette.accent : Palette.warn)
                    .background(Capsule().fill(above ? Palette.accentSoft : Palette.warnSoft))
                    .opacity(settled ? 1 : 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(score) 分，滿分 100，\(above ? "高於" : "低於") 60 分參考線")
            scoreBar(score)
            Text("國考看五科平均滿 60 分，且任一科不得 0 分；單科分數用來追蹤進步。")
                .appFont(12, relativeTo: .caption1)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                stat("\(result.correct)", "答對", color: Palette.ink)
                stat("\(result.wrong)", "答錯（已收錄）", color: Palette.warn)
                stat(ExamClock.format(exam.elapsed), "用時", color: Palette.ink)
            }
            if result.unanswered > 0 || exam.autoSubmitted {
                Text(notes)
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if let reason = exam.uncountedReason {
                Label("這次不計入成績走勢與及格推估（\(reason)）", systemImage: "info.circle")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    private var notes: String {
        var parts: [String] = []
        if exam.autoSubmitted { parts.append("時間到自動交卷") }
        if result.unanswered > 0 { parts.append("未作答 \(result.unanswered) 題（不給分）") }
        return parts.joined(separator: " ・ ")
    }

    private func scoreBar(_ score: Int) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.segmentTrack).frame(height: 10)
                Capsule().fill(score >= ExamRules.referenceLine ? Palette.accent : Palette.warn)
                    .frame(width: max(0, w * shownScore / 100), height: 10)
                Group {
                    Rectangle().fill(Palette.ink).frame(width: 2, height: 18)
                        .offset(x: w * 0.6 - 1, y: -4)
                    Text("60").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                        .fixedSize()
                        .frame(width: 30)
                        .offset(x: w * 0.6 - 15, y: 16)
                }
                .opacity(settled ? 1 : 0)
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func stat(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).appFont(20, .bold).monospacedDigit().foregroundStyle(color)
            Text(label).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("逐題對照").appFont(15, .bold).foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 12) {
                    legend(fill: Palette.accentSoft, stroke: Palette.accent, symbol: "checkmark", text: "對")
                    legend(fill: Palette.warn, stroke: Palette.warn, symbol: "xmark", text: "錯")
                    if result.unanswered > 0 {
                        legend(fill: Palette.card, stroke: Palette.chipBorder, symbol: "minus", text: "未答", dashed: true)
                    }
                }
                .appFont(12, relativeTo: .caption1)
                .foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 10), spacing: 5) {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                    resultCell(i, q)
                }
            }
        }
    }

    private func legend(fill: Color, stroke: Color, symbol: String, text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : [])))
                .frame(width: 12, height: 12)
            Text(text)
        }
    }

    private func resultCell(_ i: Int, _ q: Question) -> some View {
        let answer = i < exam.answers.count ? exam.answers[i] : ""
        let unanswered = answer.isEmpty
        let correct = ExamScoring.isCorrect(answer: answer, question: q)
        return Button {
            review = ReviewTarget(index: i, onlyWrong: false)
        } label: {
            VStack(spacing: 0) {
                Text("\(i + 1)")
                    .appFont(11, correct ? .regular : .bold, relativeTo: .caption2)
                    .monospacedDigit()
                Image(systemName: correct ? "checkmark" : (unanswered ? "minus" : "xmark"))
                    .font(.system(size: 7, weight: .heavy))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(correct ? Palette.accent : (unanswered ? Palette.muted : Palette.onWarn))
            .background(RoundedRectangle(cornerRadius: 7).fill(correct ? Palette.accentSoft : (unanswered ? Palette.card : Palette.warn)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(correct ? Palette.accent.opacity(0.4) : (unanswered ? Palette.chipBorder : Palette.warn),
                              style: StrokeStyle(lineWidth: 1, dash: unanswered ? [3, 2] : [])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(i + 1) 題\(correct ? "答對" : (unanswered ? "未作答" : "答錯"))")
        .accessibilityHint("開啟檢討")
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button(missedCount == 0 ? "檢討全部 \(questions.count) 題"
                   : (result.unanswered > 0 ? "檢討未得分的 \(missedCount) 題（錯 \(result.wrong)、未答 \(result.unanswered)）"
                      : "檢討 \(missedCount) 題錯題")) {
                review = ReviewTarget(index: firstMissed ?? 0, onlyWrong: missedCount > 0)
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
            if context == .afterExam {
                HStack(spacing: 0) {
                    Button("回到模擬考") {
                        router.tab = AppRouter.Tab.exam
                        router.activeExam = nil
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    Rectangle().fill(Palette.border).frame(width: 1, height: 20)
                    Button("回到今日") {
                        router.tab = AppRouter.Tab.today
                        router.activeExam = nil
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .appFont(16, .medium)
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .readableBarWidth()
        .background(Palette.ground.ignoresSafeArea(edges: .bottom))
    }

    private var firstMissed: Int? {
        questions.indices.first { i in
            !ExamScoring.isCorrect(answer: i < exam.answers.count ? exam.answers[i] : "", question: questions[i])
        }
    }

    // MARK: Motion

    private func countUp() {
        guard !settled else { return }
        let target = Double(exam.score)
        if reduceMotion {
            shownScore = target
            withAnimation(.easeInOut(duration: 0.2)) { settled = true }
            return
        }
        shownScore = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.8)) { shownScore = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeInOut(duration: 0.3)) { settled = true }
            }
        }
    }
}

/// Review of a finished mock: only-wrong / all toggle, answers revealed, reason chips, prev/next.
struct ExamReviewView: View {
    let exam: MockExam
    let startIndex: Int
    let onlyWrongInitially: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filter = ""
    @State private var position = 0
    @State private var forward = true
    @State private var sheetHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 120
    @State private var didInit = false

    private static let wrongKey = "wrong"
    private static let allKey = "all"

    private var questions: [Question] { exam.questionIDs.compactMap { bank.byID[$0] } }

    private func answer(_ i: Int) -> String { i < exam.answers.count ? exam.answers[i] : "" }

    private var missedIndices: [Int] {
        questions.indices.filter { !ExamScoring.isCorrect(answer: answer($0), question: questions[$0]) }
    }

    /// Blank answers are 未作答, not 錯題; the missed list then reads 「未得分」.
    private var unansweredCount: Int { missedIndices.filter { answer($0).isEmpty }.count }
    private var missedWord: String { unansweredCount > 0 ? "未得分" : "錯題" }

    private var indices: [Int] { filter == Self.wrongKey ? missedIndices : Array(questions.indices) }
    private var currentIndex: Int? { position < indices.count ? indices[position] : nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                if let i = currentIndex {
                    ForEach([i], id: \.self) { i in
                        GeometryReader { geo in
                            if Layout.isWideAnswerLayout(geo.size) {
                                // iPad landscape: question and notes left, AI 解析 right (as in `AIPracticeView`).
                                HStack(alignment: .top, spacing: 28) {
                                    ScrollView {
                                        content(i, aiInline: false)
                                            .padding(.horizontal, 12)
                                            .padding(.top, 12)
                                            .padding(.bottom, editingNote ? 24 : sheetHeight + 20)
                                    }
                                    .contentMargins(.top, topHeight, for: .scrollContent)
                                    .contentMargins(.top, topHeight, for: .scrollIndicators)
                                    .scrollDismissesKeyboard(.interactively)
                                    ScrollView {
                                        aiSection(i)
                                            .padding(.top, 12)
                                            .padding(.bottom, editingNote ? 24 : sheetHeight + 20)
                                    }
                                    .contentMargins(.top, topHeight, for: .scrollContent)
                                    .contentMargins(.top, topHeight, for: .scrollIndicators)
                                    .scrollDismissesKeyboard(.interactively)
                                    .frame(width: 500)
                                }
                                .padding(.horizontal, 28)
                                .onAppear { autoOpenAI(i, wide: true) }
                            } else {
                                ScrollView {
                                    content(i, aiInline: true)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 12)
                                        .padding(.bottom, editingNote ? 24 : sheetHeight + 20)
                                }
                                .readableScrollWidth()
                                .contentMargins(.top, topHeight, for: .scrollContent)
                                .contentMargins(.top, topHeight, for: .scrollIndicators)
                                .scrollDismissesKeyboard(.interactively)
                                .onAppear { autoOpenAI(i, wide: false) }
                            }
                        }
                        .transition(Motion.questionTransition(reduce: reduceMotion, forward: forward))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal").font(.system(size: 36)).foregroundStyle(Palette.accent)
                        Text("這份沒有錯題").appFont(17, .bold)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                topBar
                    .readHeight($topHeight)
                    .background(Palette.ground.ignoresSafeArea(edges: .top))
                    .zIndex(1)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !editingNote {
                sheet
                    .readHeight($sheetHeight)
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: setup)
        .onDisappear { aiUsage.finishAll() }
        .onChange(of: currentIndex) { old, _ in
            if let old, questions.indices.contains(old) { aiUsage.finish(questions[old].id) }
        }
        .trackScreen("question", entry: "examReview", navigation: usageNavigation)
        .sheet(item: $relatedPractice) { req in
            ReviewSessionView(request: req)
        }
        .onChange(of: filter) { old, _ in
            guard !old.isEmpty else { return }
            // Keep the same question when switching filters if it is in the new list.
            if let i = lastShown, let p = indices.firstIndex(of: i) { position = p } else { position = 0 }
        }
    }

    @State private var lastShown: Int?
    @State private var relatedPractice: SessionRequest?
    @State private var editingNote = false
    /// Questions whose AI panel is open.
    @State private var aiOpen: Set<String> = []
    @State private var aiUsage = AIUsageSessions()
    @State private var aiTriggers: [String: String] = [:]
    @State private var usageNavigation = UsageNavigation()
    /// Questions whose AI panel already opened by itself, so collapsing it sticks.
    @State private var aiAutoOpened: Set<String> = []

    /// Wide layout: every question opens its AI panel; narrow: only wrong or unanswered ones. Once per question.
    private func autoOpenAI(_ i: Int, wide: Bool) {
        let q = questions[i]
        guard !aiAutoOpened.contains(q.id), AIExplainer.shared != nil,
              AIQuestionPayload.make(q, bank: bank) != nil else { return }
        guard wide || !ExamScoring.isCorrect(answer: answer(i), question: q) else { return }
        aiAutoOpened.insert(q.id)
        AIExplainer.shared?.clearError(q.id)
        aiTriggers[q.id] = "auto"
        aiOpen.insert(q.id)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                BackButton(label: "返回成績單") { dismiss() }
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(exam.subject) ・ \(exam.title) 模擬考檢討")
                        .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Text(titleLine).appFont(16, .bold).monospacedDigit()
                }
                Spacer()
                if let i = currentIndex {
                    BookmarkButton(question: questions[i])
                        .padding(.trailing, -10)
                }
            }
            .padding(.leading, -10)
            SegmentPicker(options: [Self.wrongKey, Self.allKey], selection: $filter, height: 44) { key in
                key == Self.wrongKey ? "只看\(missedWord) \(missedIndices.count)" : "全部 \(questions.count) 題"
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var titleLine: String {
        guard let i = currentIndex else { return "\(missedWord) 0 / 0" }
        if filter == Self.wrongKey { return "\(missedWord) \(position + 1) / \(indices.count) ・ 第 \(i + 1) 題" }
        return "第 \(i + 1) / \(questions.count) 題"
    }

    private func aiSection(_ i: Int) -> some View {
        let q = questions[i]
        let mine = answer(i)
        let correct = ExamScoring.isCorrect(answer: mine, question: q)
        return AIExplainSection(question: q, order: exam.optionOrder(at: i),
                                isOpen: Binding(get: { aiOpen.contains(q.id) },
                                                set: { if $0 { aiTriggers[q.id] = "manual"; aiOpen.insert(q.id) } else { aiOpen.remove(q.id) } }),
                                wrongChoice: !mine.isEmpty && !correct && Question.letters.contains(mine) ? mine : nil,
                                trigger: aiTriggers[q.id] ?? "manual", usage: aiUsage.session(q.id),
                                onInputFocus: { f in withAnimation(.easeInOut(duration: 0.2)) { editingNote = f } })
    }

    private func content(_ i: Int, aiInline: Bool) -> some View {
        let q = questions[i]
        let mine = answer(i)
        let correct = ExamScoring.isCorrect(answer: mine, question: q)
        return VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Chip(text: q.subject, kind: .subject)
                Chip(text: q.sourceLabel)
                if mine.isEmpty { Chip(text: "未作答", kind: .notice) }
                if q.corrected || q.allCredit { Chip(text: "有更正答案", kind: .notice) }
            }
            QuestionStem(question: q, fontSize: 17)
            // Same order the user saw while answering (persisted per exam question).
            OrderedOptions(question: q, order: exam.optionOrder(at: i), state: { state($0, q, mine) },
                           tag: { tag($0, q, mine) }, spacing: 8) { _ in }
                .allowsHitTesting(false)
            if let text = AnswerPresentation(question: q, order: exam.optionOrder(at: i), chosen: mine).correctionText {
                Text(text)
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice))
            }
            Text(footnote(i, mine: mine, correct: correct))
                .appFont(12, relativeTo: .caption1)
                .foregroundStyle(Palette.muted)
            if aiInline {
                aiSection(i)
                    .padding(.top, 4)
            }
            QuestionDetailExtras(question: q, onNoteFocus: { f in
                withAnimation(.easeInOut(duration: 0.2)) { editingNote = f }
            }) { related in
                relatedPractice = SessionRequest(queue: [related.id], doneBefore: 0, isDaily: false, isPractice: true)
            }
            .padding(.top, 8)
        }
    }

    private func footnote(_ i: Int, mine: String, correct: Bool) -> String {
        let time = i < exam.seconds.count && exam.seconds[i] >= 1 ? "作答用時 \(ExamClock.duration(exam.seconds[i]))" : "沒有停留紀錄"
        if mine.isEmpty { return "\(time) ・ 未作答，不給分" }
        return correct ? "\(time) ・ 答對" : "\(time) ・ 已自動收進錯題本"
    }

    private func state(_ letter: String, _ q: Question, _ mine: String) -> OptionRow.State {
        let accepted = q.allCredit ? Set([mine, q.originalAnswer ?? ""].filter { !$0.isEmpty }) : Set(q.answer)
        if accepted.contains(letter) { return .correct }
        if letter == mine { return .mine }
        return .idle
    }

    private func tag(_ letter: String, _ q: Question, _ mine: String) -> String {
        let accepted = q.allCredit ? Set([mine, q.originalAnswer ?? ""].filter { !$0.isEmpty }) : Set(q.answer)
        if accepted.contains(letter) {
            return letter == mine ? "正確答案\n你的答案" : (q.corrected || q.allCredit ? "給分" : "正確答案")
        }
        return letter == mine ? "你的答案" : ""
    }

    // MARK: Sheet

    private var sheet: some View {
        let i = currentIndex
        let wrongAnswered = i.map { !answer($0).isEmpty && !ExamScoring.isCorrect(answer: answer($0), question: questions[$0]) } ?? false
        let current = i.flatMap { $0 < exam.reasons.count ? exam.reasons[$0] : nil } ?? ""
        let unit = filter == Self.wrongKey ? missedWord : "題"
        return VStack(alignment: .leading, spacing: 12) {
            if wrongAnswered, let i {
                (Text("這題錯在哪？").bold() + Text("（可略過）").font(.system(size: 13)).foregroundColor(Palette.muted))
                    .appFont(15)
                HStack(spacing: 8) {
                    ForEach(MistakeReason.all, id: \.self) { label in
                        let on = current == label
                        Button {
                            Haptics.selection()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                StudyStore(context: context).setReason(on ? nil : label, exam: exam, index: i)
                            }
                        } label: {
                            Text(label).appFont(14, .medium, relativeTo: .subheadline)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(on ? Palette.onAccent : Palette.ink)
                                .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accent : Palette.card))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Palette.accent : Palette.chipBorder, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 10) {
                Button("上一\(unit)") { move(-1) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(position == 0)
                Button(position >= indices.count - 1 ? "回成績單" : "下一\(unit)") {
                    if position >= indices.count - 1 { dismiss() } else { move(1) }
                }
                .buttonStyle(PrimaryButtonStyle(height: 50))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .readableBarWidth()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(Palette.card)
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func setup() {
        guard !didInit else { return }
        didInit = true
        filter = onlyWrongInitially && !missedIndices.isEmpty ? Self.wrongKey : Self.allKey
        position = indices.firstIndex(of: startIndex) ?? 0
        lastShown = currentIndex
    }

    private func move(_ delta: Int) {
        let target = position + delta
        guard target >= 0, target < indices.count else { return }
        if delta < 0 { usageNavigation.previousUsed = true } else { usageNavigation.nextUsed = true }
        let qid = questions[indices[target]].id
        if aiOpen.contains(qid) { aiTriggers[qid] = "auto" }
        forward = delta > 0
        DispatchQueue.main.async {
            withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { position = target }
            lastShown = indices[target]
        }
    }
}

/// Small tag for finished exams left out of the score trend and pass projection.
struct UncountedTag: View {
    var body: some View {
        Text("未計入成績")
            .appFont(11, .medium, relativeTo: .caption2)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.badge))
            .lineLimit(1)
            .fixedSize()
    }
}
