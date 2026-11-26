import SwiftUI
import SwiftData

/// 「AI 出題，非官方・AI 自動檢核」 label above every AI question.
struct AIBadge: View {
    var body: some View {
        Text("AI 出題，非官方・AI 自動檢核")
            .appFont(11, .bold, relativeTo: .caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(Palette.noticeInk)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.notice))
            .fixedSize()
    }
}

/// ☆ of an AI question (the same QuestionNote as official questions, keyed by the `ai:` id).
struct AIBookmarkButton: View {
    let question: AIQuestion
    @Environment(\.modelContext) private var context
    @State private var on = false

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { on.toggle() }
            StudyStore(context: context).setAIBookmark(on, question: question)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? Palette.warn : Palette.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏這題")
        .accessibilityAddTraits(on ? .isSelected : [])
        .onAppear { on = StudyStore(context: context).isAIBookmarked(question.id) }
        .onChange(of: question.id) { on = StudyStore(context: context).isAIBookmarked(question.id) }
    }
}

/// One practice round over AI questions (docs/AI出題與圖解.md 4): no review cards, no streak, no daily goal.
struct AIPracticeView: View {
    let ids: [String]
    /// Open one question in its answered state without recording anything (from AI 錯題 and 收藏).
    var reviewing: (id: String, chosen: String)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index = 0
    @State private var usageNavigation = UsageNavigation()
    @State private var picks: [Int: String] = [:]
    @State private var revealed: Set<Int> = []
    @State private var attempts: [Int: AttemptRecord] = [:]
    @State private var guessed: Set<Int> = []
    @State private var correctCount = 0
    @State private var wrongCount = 0
    @State private var finished = false
    @State private var reportQuestion: AIQuestion?
    @State private var reportToast = false
    @State private var sourceRoute: QuestionDetailRoute?
    @State private var pointLabel: [Int: String] = [:]
    @State private var started = false

    private var questions: [AIQuestion] { ids.compactMap { bank.ai.byID[$0] } }
    private var current: AIQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    private var store: StudyStore { StudyStore(context: context) }
    private var answered: Bool { picks[index] != nil }

    var body: some View {
        GeometryReader { geo in
            let wide = Layout.isWideAnswerLayout(geo.size)
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    topBar
                    if finished {
                        completion
                    } else if let q = current {
                        if wide { twoColumn(q) } else { singleColumn(q) }
                    } else {
                        emptyState
                    }
                }
                if !finished, let q = current {
                    bottomBar(q)
                }
                if reportToast {
                    Toast(text: "已回報，謝謝")
                        .padding(.horizontal, 20).padding(.bottom, 80)
                        .transition(.opacity)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .trackScreen("aiQuestion", answerSource: "ai", navigation: usageNavigation)
        .firstVisitTip(key: SettingsKey.tipAIQuestionShown, title: "這是 AI 出的題",
                       message: "AI 照歷屆計算題的算法換數字出題，非官方：只算一半進考點掌握度，不進每日複習和成績。作答後有解題步驟和圖解；覺得題目或圖不對，按「⋯」的「題目有誤」或圖下方的「圖有誤」。",
                       docked: true)
        .onAppear(perform: start)
        .sheet(item: $reportQuestion) { q in
            AIQuestionReportSheet(question: q) { showReportToast($reportToast) }
        }
        .sheet(item: $sourceRoute) { route in
            NavigationStack {
                QuestionDetailView(route: route).interactivePopEnabled()
            }
        }
    }

    // MARK: Layout

    private func singleColumn(_ q: AIQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                questionBlock(q)
                if answered { resultCard(q).padding(.top, 6) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .readableScrollWidth()
        .id(q.id)
        .transition(Motion.questionTransition(reduce: reduceMotion))
    }

    private func twoColumn(_ q: AIQuestion) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { questionBlock(q) }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 120)
            }
            ScrollView {
                if answered { resultCard(q) }
            }
            .frame(width: 500)
            .padding(.bottom, 90)
        }
        .padding(.horizontal, 28)
        .id(q.id)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("沒有可練的 AI 題").appFont(17, .bold)
            Text("這個範圍目前沒有 AI 出的題。").appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
            Button("返回") { dismiss() }.buttonStyle(SecondaryButtonStyle()).padding(.top, 12).padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        let total = max(1, questions.count)
        let fraction = Double(min(index + (answered || finished ? 1 : 0), total)) / Double(total)
        return HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("結束練習")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.border)
                    Capsule().fill(Palette.accent).frame(width: geo.size.width * fraction)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 6)
            Text("\(min(index + 1, total)) / \(total)").appFont(14, .bold, relativeTo: .subheadline).monospacedDigit()
                .frame(minWidth: 54)
            if let q = current, !finished {
                HStack(spacing: 0) {
                    AIBookmarkButton(question: q)
                    Menu {
                        Button { reportQuestion = q } label: {
                            Label(QuestionReport.isReported(q.id) ? "題目有誤（已回報過）" : "題目有誤",
                                  systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Palette.ink).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")
                }
                .padding(.trailing, -6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    // MARK: Question

    private func questionBlock(_ q: AIQuestion) -> some View {
        let point = q.pointIDs.first.flatMap { bank.learning.pointByID[$0] }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                AIBadge().coachTarget()
                Text([q.subject, point.map { "考點：\($0.title)" }].compactMap { $0 }.joined(separator: " ・ "))
                    .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            Text(q.stem).appFont(17).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 2)
            ForEach(Question.letters, id: \.self) { letter in
                if let text = q.options[letter] {
                    OptionRow(letter: letter, text: text, state: optionState(letter, q), tag: optionTag(letter, q)) {
                        choose(letter, in: q)
                    }
                }
            }
        }
    }

    private func optionState(_ letter: String, _ q: AIQuestion) -> OptionRow.State {
        guard answered else { return .idle }
        if letter == q.answer { return .correct }
        return picks[index] == letter ? .mine : .idle
    }

    private func optionTag(_ letter: String, _ q: AIQuestion) -> String {
        guard answered else { return "" }
        if letter == q.answer { return "正確答案" }
        return picks[index] == letter ? "你的答案" : ""
    }

    // MARK: Result

    private func resultCard(_ q: AIQuestion) -> some View {
        let chosen = picks[index] ?? ""
        let correct = q.isCorrect(chosen) && !revealed.contains(index)
        let note = (!correct && !revealed.contains(index)) ? q.wrongNotes[chosen] : nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: correct ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(correct ? Palette.accent : Palette.warn)
                Text(correct ? "答對了" : (revealed.contains(index) ? "看了解答" : "答錯了")).appFont(18, .bold)
                Spacer(minLength: 8)
                if correct && reviewing == nil {
                    guessToggle
                } else if let label = pointLabel[index] {
                    Text("考點掌握度：\(label)").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                }
            }
            if let note {
                (Text("你選了 \(chosen)：").bold().foregroundColor(Palette.warn) + Text(note))
                    .appFont(14, relativeTo: .subheadline).lineSpacing(4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.warnSoft))
            }
            if correct, let label = pointLabel[index] {
                Text("考點掌握度：\(label)").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("解題步驟").appFont(15, .bold).accessibilityAddTraits(.isHeader)
                    Text("程式依公式計算").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                }
                ForEach(Array(q.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").appFont(12, .bold, relativeTo: .caption1)
                            .foregroundStyle(Palette.accent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.accentSoft))
                            .padding(.top, 2)
                        Text(step).appFont(15).lineSpacing(4).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("答案 \(q.answer)：\(q.answerText)").appFont(15, .bold).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentSoft))
            }
            AIFigureCard(question: q)
            if let source = q.sourceQuestionID, let official = bank.byID[source] {
                Button {
                    Haptics.selection()
                    sourceRoute = QuestionDetailRoute(entry: "aiQuestion", id: source, ids: [source], backLabel: "返回 AI 題")
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("這題的算法來自歷屆").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                            Text("\(official.year) 年 \(official.subject) 第 \(official.number) 題").appFont(15, .bold)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("看原題").appFont(14, .medium).foregroundStyle(Palette.accent)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.ground))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
        .transition(.opacity)
    }

    private var guessToggle: some View {
        let on = guessed.contains(index)
        return Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) {
                if on { guessed.remove(index) } else { guessed.insert(index) }
            }
            if let a = attempts[index] {
                a.unsure = !on
                try? context.save()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22)).foregroundStyle(on ? Palette.accent : Palette.muted)
                Text("猜的").appFont(14, relativeTo: .subheadline).fixedSize()
            }
            .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("猜的")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(_ q: AIQuestion) -> some View {
        if answered {
            GeometryReader { geo in
                HStack(spacing: 8) {
                    Button("題目有誤") { reportQuestion = q }
                        .buttonStyle(.plain)
                        .appFont(15)
                        .frame(width: (geo.size.width - 8) / 3, height: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border, lineWidth: 1))
                    Button(isLast ? "完成" : "下一題") { advance() }
                        .buttonStyle(PrimaryButtonStyle(height: 52))
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
            .readableBarWidth()
            .background(Palette.card.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        } else {
            Button("看解答") { reveal(in: q) }
                .appFont(15, .medium)
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }

    private var isLast: Bool { reviewing != nil || index >= questions.count - 1 }

    // MARK: Completion

    private var completion: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(Palette.accent)
            Text("這一輪完成了").headingFont(28)
            VStack(spacing: 6) {
                Text("練了 \(questions.count) 題").appFont(17).foregroundStyle(Palette.muted)
                if wrongCount > 0 {
                    Text("其中 \(wrongCount) 題答錯，已放進錯題本的「AI 錯題」").appFont(17).foregroundStyle(Palette.muted)
                }
            }
            .multilineTextAlignment(.center)
            Spacer()
            Button("完成") { dismiss() }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 4)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .readableBarWidth()
    }

    // MARK: Actions

    private func start() {
        guard !started else { return }
        started = true
        if let reviewing, let i = ids.firstIndex(of: reviewing.id) {
            index = i
            picks[i] = reviewing.chosen.isEmpty ? "-" : reviewing.chosen
            if reviewing.chosen.isEmpty { revealed.insert(i) }
            if let q = bank.ai.byID[reviewing.id] { updateLabel(q, slot: i) }
        }
    }

    private func choose(_ letter: String, in q: AIQuestion) {
        guard !answered, reviewing == nil else { return }
        Haptics.answer()
        withAnimation(Motion.answerReveal) { picks[index] = letter }
        let attempt = store.commitAI(question: q, chosen: letter, unsure: false)
        attempts[index] = attempt
        if q.isCorrect(letter) { correctCount += 1 } else { wrongCount += 1 }
        updateLabel(q, slot: index)
    }

    private func reveal(in q: AIQuestion) {
        guard !answered, reviewing == nil else { return }
        withAnimation(Motion.answerReveal) { picks[index] = "-" }
        revealed.insert(index)
        attempts[index] = store.commitAI(question: q, chosen: "", unsure: false, revealed: true)
        wrongCount += 1
        updateLabel(q, slot: index)
    }

    private func updateLabel(_ q: AIQuestion, slot: Int) {
        guard let pid = q.pointIDs.first, let point = bank.learning.pointByID[pid] else { return }
        let stats = PointStatsLoader.load(context: context, bank: bank, questions: bank.questions, points: [point])
        pointLabel[slot] = stats[pid]?.label.title
    }

    private func advance() {
        Haptics.selection()
        if reviewing != nil || isLast {
            if reviewing != nil { dismiss() } else { withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { finished = true } }
            return
        }
        usageNavigation.nextUsed = true
        withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { index += 1 }
    }
}
