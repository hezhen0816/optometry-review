import SwiftUI
import SwiftData
import Combine

/// Five-subject full mock: overview with the break between subjects, the exam screen per subject, then the result.
/// Scores stay hidden until all five subjects are submitted.
struct FullMockFlowView: View {
    let full: FullMock

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router

    private enum Phase: Equatable { case overview, exam, result }
    @State private var phase: Phase
    @State private var exam: MockExam?

    init(full: FullMock) {
        self.full = full
        _phase = State(initialValue: full.isFinished ? .result : .overview)
    }

    private var store: StudyStore { StudyStore(context: context) }

    var body: some View {
        NavigationStack {
            ZStack {
                switch phase {
                case .overview:
                    FullMockOverview(full: full, onStart: startSubject, onLeave: leave)
                        .trackScreen("fullMock")
                        .transition(.opacity)
                case .exam:
                    if let exam {
                        ExamView(exam: exam, onFinished: subjectSubmitted, onLeave: leave)
                            .id(exam.examID)
                            .transition(.opacity)
                    }
                case .result:
                    FullMockResultView(full: full, context: .afterExam)
                        .transition(.opacity)
                }
            }
            .interactivePopEnabled()
        }
    }

    private func startSubject() {
        // A full mock opened from 模擬考 is saved only when its first subject starts.
        if full.modelContext == nil {
            full.startedAt = .now
            context.insert(full)
            try? context.save()
        }
        guard let next = store.nextSubjectExam(of: full, bank: bank) else { return }
        exam = next
        withAnimation(.easeInOut(duration: 0.3)) { phase = .exam }
    }

    private func subjectSubmitted() {
        let exams = store.subjectExams(of: full)
        if exams.count == Subjects.all.count && exams.allSatisfy(\.isSubmitted) {
            store.completeFullMock(full, bank: bank)
            withAnimation(.easeInOut(duration: 0.3)) { phase = .result }
        } else {
            full.breakStartedAt = .now
            try? context.save()
            withAnimation(.easeInOut(duration: 0.3)) { phase = .overview }
        }
    }

    private func leave() {
        try? context.save()
        router.activeFullMock = nil
    }
}

/// Progress list, 科間休息 countdown and the start button for the next subject.
private struct FullMockOverview: View {
    let full: FullMock
    let onStart: () -> Void
    let onLeave: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var exams: [MockExam] { StudyStore(context: context).subjectExams(of: full) }
    private var submitted: Int { exams.filter(\.isSubmitted).count }
    /// Subject being answered (started, not submitted).
    private var openExam: MockExam? { exams.first { !$0.isSubmitted } }
    private var nextIndex: Int { min(submitted, Subjects.all.count - 1) }
    private var nextPaper: Paper? { bank.paperByID[Paper.makeID(code: full.code, subject: Subjects.all[nextIndex])] }
    private var breakRemaining: Double { FullMockRules.breakRemaining(startedAt: full.breakStartedAt, now: now) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: onLeave) {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -10)
                    .accessibilityLabel(full.modelContext == nil ? "離開" : "暫停並離開")
                    .accessibilityHint(full.modelContext == nil ? "" : "進度會保存，可在模擬考分頁繼續")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(full.displayLabel) ・ 第 \(nextIndex + 1) 科／共 5 科")
                            .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        Text("五科連考模擬").headingFont(28)
                    }
                    steps
                    nextCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .readableScrollWidth()
            Button(buttonTitle, action: onStart)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Palette.ground)
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(ticker) { now = $0 }
    }

    private var buttonTitle: String {
        openExam != nil ? "繼續第 \(nextIndex + 1) 科" : (full.breakStartedAt != nil && breakRemaining > 0 ? "跳過休息，開始第 \(nextIndex + 1) 科" : "開始第 \(nextIndex + 1) 科")
    }

    private var steps: some View {
        VStack(spacing: 0) {
            ForEach(Array(Subjects.all.enumerated()), id: \.offset) { i, name in
                let done = i < submitted
                let isNext = i == nextIndex && !done
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(done ? Palette.accent : Palette.card)
                        Circle().strokeBorder(isNext ? Palette.accent : Palette.chipBorder, lineWidth: done ? 0 : (isNext ? 2 : 1.5))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.onAccent)
                        } else {
                            Text("\(i + 1)").appFont(13, .bold, relativeTo: .footnote)
                        }
                    }
                    .frame(width: 26, height: 26)
                    Text(name).appFont(15, isNext ? .bold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(done ? "已交卷" : (isNext ? (openExam != nil ? "作答中" : "接著考") : "待考"))
                        .appFont(13, relativeTo: .footnote)
                        .foregroundStyle(isNext ? Palette.accent : Palette.muted)
                }
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
                if i < Subjects.all.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private var nextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if full.breakStartedAt != nil && openExam == nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("科間休息").appFont(15, .bold)
                    Spacer()
                    if breakRemaining > 0 {
                        Text(ExamClock.format(breakRemaining))
                            .appFont(28, .bold, relativeTo: .title1)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .accessibilityLabel("休息剩 \(Int(breakRemaining) / 60) 分 \(Int(breakRemaining) % 60) 秒")
                    } else {
                        Text("休息時間到").appFont(15, .bold).foregroundStyle(Palette.accent)
                    }
                }
            } else {
                Text(openExam != nil ? "作答到一半" : "下一科").appFont(15, .bold)
            }
            VStack(alignment: .leading, spacing: 4) {
                (Text("科目　　").foregroundColor(Palette.muted)
                 + Text("\(Subjects.all[nextIndex]) ・ 50 題 ・ 60 分鐘"))
                (Text("計算器　").foregroundColor(Palette.muted) + Text(calculatorText))
                if let open = openExam {
                    (Text("進度　　").foregroundColor(Palette.muted)
                     + Text("已答 \(open.answeredCount) 題 ・ 剩 \(ExamClock.format(ExamRules.durationSeconds - open.elapsed))"))
                        .monospacedDigit()
                }
            }
            .appFont(14, relativeTo: .subheadline)
            .lineSpacing(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private var calculatorText: String {
        guard let p = nextPaper else { return "—" }
        return p.calculatorAllowed ? "可使用（\(full.label)試卷註記）" : "禁止使用（\(full.label)試卷註記）"
    }
}

/// Animates a one-decimal average (count-up).
private struct DecimalCountText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(String(format: "%.1f", value)) }
}

/// 五科連考成績: average, the two pass conditions, per-subject scores and wrong counts.
struct FullMockResultView: View {
    enum Context { case afterExam, history }

    let full: FullMock
    let context: Context

    @Environment(\.modelContext) private var modelContext
    @Environment(\.questionBank) private var bank
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router

    @State private var shown: Double = 0
    @State private var settled = false
    @State private var showReview = false

    private var exams: [MockExam] { StudyStore(context: modelContext).subjectExams(of: full) }
    private var judgment: FullMockJudgment { FullMockJudgment(scores: exams.map(\.score)) }

    private func missed(_ e: MockExam) -> Int { e.questionIDs.count - e.correctCount }
    private func unanswered(_ e: MockExam) -> Int { e.questionIDs.count - e.answeredCount }
    private var totalMissed: Int { exams.map(missed).reduce(0, +) }
    private var totalUnanswered: Int { exams.map(unanswered).reduce(0, +) }

    /// 「錯 3 題」, or 「錯 2・未答 1」 when some were left blank (blank is not a wrong answer).
    private func missedText(_ e: MockExam) -> String {
        let blank = unanswered(e)
        return blank > 0 ? "錯 \(missed(e) - blank)・未答 \(blank)" : "錯 \(missed(e)) 題"
    }

    var body: some View {
        let j = judgment
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if context == .history {
                        BackButton(label: "返回考試紀錄") { dismiss() }
                            .padding(.leading, -10)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(full.displayLabel) ・ 五科連考模擬")
                            .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        Text("總成績").headingFont(28)
                    }
                    .padding(.top, context == .history ? 0 : 20)
                    summaryCard(j)
                    subjectRows
                    if let hint = hint(j) {
                        Text(hint).appFont(13, relativeTo: .footnote).lineSpacing(3).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .readableScrollWidth()
            buttons
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showReview) { FullMockReviewList(full: full) }
        .onAppear(perform: countUp)
        .trackScreen("fullMock")
    }

    private func summaryCard(_ j: FullMockJudgment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("五科平均").appFont(13, relativeTo: .footnote).opacity(0.9)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ZStack(alignment: .trailing) {
                            Text(ScoreHistory.format(j.average)).hidden()
                            DecimalCountText(value: shown)
                        }
                        .appFont(48, .bold, relativeTo: .largeTitle)
                        .monospacedDigit()
                        Text("分").appFont(15).opacity(0.9)
                    }
                }
                Spacer()
                Text(j.passed ? "及格" : "未達")
                    .appFont(16, .bold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(j.passed ? Palette.heroFill : Palette.heroWarn)
                    .background(Capsule().fill(Color.white))
                    .opacity(settled ? 1 : 0)
                    .scaleEffect(settled || reduceMotion ? 1 : 0.9)
            }
            VStack(alignment: .leading, spacing: 4) {
                condition(j.averageOK, "五科平均 \(ScoreHistory.format(j.average)) \(j.averageOK ? "≥" : "<") 60")
                condition(j.noZero, j.noZero ? "沒有任何一科 0 分" : "有科目 0 分（任一科 0 分不及格）")
            }
            .opacity(settled ? 1 : 0)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.heroFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("五科平均 \(ScoreHistory.format(j.average)) 分，\(j.passed ? "及格" : "未達")。"
            + "平均\(j.averageOK ? "達到" : "未達") 60 分，\(j.noZero ? "沒有 0 分的科目" : "有科目 0 分")")
    }

    private func condition(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark" : "xmark").font(.system(size: 13, weight: .heavy))
                .frame(width: 16)
            Text(text).appFont(14, relativeTo: .subheadline)
        }
    }

    private var subjectRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(exams.enumerated()), id: \.element.examID) { i, e in
                NavigationLink {
                    ExamResultView(exam: e, context: .history)
                } label: {
                    subjectRow(e)
                }
                .buttonStyle(.plain)
                if i < exams.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func subjectRow(_ e: MockExam) -> some View {
        let low = e.score < ExamRules.referenceLine
        return VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    Text(e.subject).appFont(15, low ? .bold : .regular)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if !e.countsTowardScores { UncountedTag() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(missedText(e)).appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
                Text("\(e.score)").appFont(17, .bold).monospacedDigit()
                    .foregroundStyle(e.score == 0 ? Palette.warn : Palette.ink)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.segmentTrack)
                    Capsule().fill(low ? Palette.warn : Palette.chart)
                        .frame(width: geo.size.width * CGFloat(e.score) / 100 * (settled || reduceMotion ? 1 : 0))
                    Rectangle().fill(Palette.ink).frame(width: 2, height: 12)
                        .offset(x: geo.size.width * 0.6 - 1)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(e.subject) \(e.score) 分，\(missedText(e))")
        .accessibilityHint("開啟這科成績單")
    }

    /// Factual one-liner: margin over the line, and what raising the lowest subject to 60 would do.
    private func hint(_ j: FullMockJudgment) -> String? {
        guard exams.count == Subjects.all.count else { return nil }
        var parts: [String] = []
        let margin = j.average - Double(ExamRules.referenceLine)
        if j.passed {
            parts.append("比及格線多 \(ScoreHistory.format(margin)) 分。")
        } else if !j.averageOK {
            parts.append("平均還差 \(ScoreHistory.format(-margin)) 分。")
        }
        if !j.noZero {
            let zeroSubjects = exams.filter { $0.score == 0 }.map(\.subject).joined(separator: "、")
            parts.append("\(zeroSubjects) 0 分；國考任一科 0 分就不及格，平均再高也一樣。")
        } else if let low = j.averageIfLowestAt60 {
            parts.append("\(exams[low.index].subject)拉回 60 分，平均就有 \(ScoreHistory.format(low.average)) 分。")
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    private func leave(to tab: Int) {
        router.tab = tab
        router.activeFullMock = nil
    }

    private var buttons: some View {
        VStack(spacing: 2) {
        HStack(spacing: 10) {
            Button(totalMissed == 0 ? "檢討各科"
                   : totalUnanswered > 0 ? "檢討 \(totalMissed) 題未得分" : "檢討 \(totalMissed) 題錯題") { showReview = true }
                .buttonStyle(SecondaryButtonStyle())
            if context == .afterExam {
                Button("回到模擬考") { leave(to: AppRouter.Tab.exam) }
                    .buttonStyle(PrimaryButtonStyle(height: 52))
            }
        }
        if context == .afterExam {
            Button("回到今日") { leave(to: AppRouter.Tab.today) }
                .appFont(16, .medium)
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain)
        }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .readableBarWidth()
        .background(Palette.ground.ignoresSafeArea(edges: .bottom))
    }

    private func countUp() {
        guard !settled else { return }
        let target = judgment.average
        if reduceMotion {
            shown = target
            withAnimation(.easeInOut(duration: 0.2)) { settled = true }
            return
        }
        shown = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.8)) { shown = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { settled = true }
            }
        }
    }
}

/// Wrong answers of a full mock, grouped by subject.
struct FullMockReviewList: View {
    let full: FullMock

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.dismiss) private var dismiss

    private var exams: [MockExam] { StudyStore(context: context).subjectExams(of: full) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BackButton(label: "返回總成績") { dismiss() }
                    .padding(.leading, -10)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(full.displayLabel) ・ 五科連考模擬").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    Text("檢討").headingFont(28)
                    Text("答錯的題目已收進錯題本，照間隔排進每日複習。").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                }
                VStack(spacing: 0) {
                    ForEach(Array(exams.enumerated()), id: \.element.examID) { i, e in
                        NavigationLink {
                            ExamReviewView(exam: e, startIndex: firstMissed(e) ?? 0, onlyWrongInitially: true)
                        } label: {
                            row(e)
                        }
                        .buttonStyle(.plain)
                        if i < exams.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func firstMissed(_ e: MockExam) -> Int? {
        let qs = e.questionIDs.compactMap { bank.byID[$0] }
        return qs.indices.first { !ExamScoring.isCorrect(answer: $0 < e.answers.count ? e.answers[$0] : "", question: qs[$0]) }
    }

    private func row(_ e: MockExam) -> some View {
        let n = e.questionIDs.count - e.correctCount
        let blank = e.questionIDs.count - e.answeredCount
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.subject).appFont(15, .bold)
                Text("\(e.score) 分").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(n == 0 ? "全對" : blank > 0 ? "錯 \(n - blank)・未答 \(blank)" : "錯 \(n) 題").appFont(15, .bold).monospacedDigit()
                .foregroundStyle(n > 0 ? Palette.warn : Palette.accent)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension FullMock {
    /// "113 年 一般"; sessions with a note ("106 年 花東補辦") keep their label.
    var displayLabel: String { label.contains(" ") && !label.hasSuffix("年") ? label : "\(label) 一般" }
}
