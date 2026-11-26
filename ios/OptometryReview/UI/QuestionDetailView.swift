import SwiftUI
import SwiftData

/// 上一題／下一題 through the list the detail was opened from, in that list's order.
struct QuestionPager: Equatable {
    let ids: [String]
    private(set) var index: Int

    /// A `current` missing from `ids` pages nowhere.
    init(ids: [String], current: String) {
        let list = ids.contains(current) ? ids : [current]
        self.ids = list
        index = list.firstIndex(of: current) ?? 0
    }

    var current: String { ids[index] }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index < ids.count - 1 }

    /// Moves by `offset`; false (and no move) past either end.
    @discardableResult
    mutating func step(_ offset: Int) -> Bool {
        let next = index + offset
        guard ids.indices.contains(next) else { return false }
        index = next
        return true
    }
}

/// Whether the detail shows the answer. Default: answered questions show it, never-answered ones stay hidden;
/// 設定「題目頁預設遮住答案」 hides every question. 「顯示答案／隱藏答案」 overrides the current question only
/// and paging drops the override.
struct DetailAnswerVisibility {
    /// Set by the button for the current question; nil = default.
    private(set) var override: Bool?

    func shows(answered: Bool, hideByDefault: Bool) -> Bool {
        override ?? (answered && !hideByDefault)
    }

    mutating func toggle(answered: Bool, hideByDefault: Bool) {
        override = !shows(answered: answered, hideByDefault: hideByDefault)
    }

    /// Paging to another question: back to that question's default.
    mutating func reset() { override = nil }
}

/// Read-only question page opened from a list: the official answer, the user's history, note, ☆ and AI 解析.
/// Viewing records nothing, including 「顯示答案」.
struct QuestionDetailView: View {
    /// VoiceOver label of the back button, naming the screen it returns to.
    let backLabel: String
    let usageEntry: String

    init(route: QuestionDetailRoute) {
        backLabel = route.backLabel
        usageEntry = route.entry
        _pager = State(initialValue: QuestionPager(ids: route.ids, current: route.id))
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank

    @AppStorage(SettingsKey.detailHidesAnswer) private var hideByDefault = false
    @State private var pager: QuestionPager
    @State private var answer = DetailAnswerVisibility()
    @State private var history = QuestionHistory.empty
    @State private var aiOpen = false
    @State private var aiTrigger = "manual"
    @State private var aiUsage = AIUsageSessions()
    @State private var usageNavigation = UsageNavigation()
    /// Questions whose AI panel already opened by itself (wide layout), so collapsing it sticks.
    @State private var aiAutoOpened: Set<String> = []
    @State private var editing = false
    @State private var reportQuestion: Question?
    @State private var reportToast = false
    /// 「移出複習」/「移回複習」, same as the session's ⋯ menu.
    @State private var parked = false
    @State private var confirmPark = false
    @State private var parkToast: String?

    private var questionID: String { pager.current }
    private var question: Question? { bank.byID[questionID] }
    private var showsAnswer: Bool {
        answer.shows(answered: !history.entries.isEmpty, hideByDefault: hideByDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let q = question {
                GeometryReader { geo in
                    if Layout.isWideAnswerLayout(geo.size) {
                        // iPad landscape: question and notes left, AI 解析 right (as in `AIPracticeView`).
                        HStack(alignment: .top, spacing: 28) {
                            ScrollView {
                                content(q, aiInline: false)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 24)
                            }
                            .scrollDismissesKeyboard(.interactively)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    if showsAnswer {
                                        aiSection(q)
                                    }
                                }
                                .padding(.top, 8)
                                .padding(.bottom, 24)
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .frame(width: 500)
                        }
                        .padding(.horizontal, 28)
                        .id(questionID)
                        .onAppear { autoOpenAI(q) }
                        .onChange(of: showsAnswer) { autoOpenAI(q) }
                    } else {
                        ScrollView {
                            content(q, aiInline: true)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                                .padding(.bottom, 24)
                        }
                        .readableScrollWidth()
                        .scrollDismissesKeyboard(.interactively)
                        .id(questionID)
                    }
                }
            } else {
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if question != nil && !editing && pager.ids.count > 1 { pagingBar }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .trackScreen("questionDetail", entry: usageEntry, navigation: usageNavigation)
        .onAppear(perform: load)
        .onDisappear { aiUsage.finishAll() }
        .onChange(of: showsAnswer) { _, visible in if !visible { aiUsage.finish(questionID) } }
        .overlay(alignment: .bottom) {
            if let text = parkToast ?? (reportToast ? "已回報，謝謝" : nil) {
                Toast(text: text)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 84)
                    .transition(.opacity)
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
        .sheet(item: $reportQuestion) { q in
            QuestionReportSheet(question: q) { showReportToast($reportToast) }
        }
    }

    private var store: StudyStore { StudyStore(context: context, scheduler: Scheduler(examDate: SettingsKey.examDateValue)) }

    private func load() {
        history = QuestionHistory.load(questionID: questionID, store: store)
        parked = store.record(for: questionID)?.parked ?? false
    }

    private func park() {
        guard store.park(questionID: questionID) else { return }
        Haptics.selection()
        parked = true
        flash("已移出複習")
    }

    private func unpark() {
        guard store.unpark(questionID: questionID) else { return }
        Haptics.selection()
        parked = false
        flash("已移回複習")
    }

    private func flash(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) { parkToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) { if parkToast == text { parkToast = nil } }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            BackButton(label: backLabel) { dismiss() }
            Spacer()
            if let q = question {
                BookmarkButton(question: q)
                Menu {
                    if parked {
                        Button { unpark() } label: { Label("移回複習", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button(role: .destructive) { confirmPark = true } label: { Label("移出複習", systemImage: "minus.circle") }
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
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    /// Wide layout: once the answer is visible, open the AI panel by itself, once per question.
    private func autoOpenAI(_ q: Question) {
        guard showsAnswer, !aiAutoOpened.contains(q.id),
              AIExplainer.shared != nil, AIQuestionPayload.make(q, bank: bank) != nil else { return }
        aiAutoOpened.insert(q.id)
        AIExplainer.shared?.clearError(q.id)
        aiTrigger = "auto"
        aiOpen = true
    }

    private func aiSection(_ q: Question) -> some View {
        AIExplainSection(question: q, order: .original,
                         isOpen: Binding(get: { aiOpen }, set: { open in
                             if open { aiTrigger = "manual" }
                             aiOpen = open
                         }), trigger: aiTrigger, usage: aiUsage.session(q.id),
                         onInputFocus: { f in withAnimation(.easeInOut(duration: 0.2)) { editing = f } })
    }

    private func content(_ q: Question, aiInline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Chip(text: q.subject, kind: .subject)
                Chip(text: q.sourceLabel)
                if q.corrected || q.allCredit { Chip(text: "有更正答案", kind: .notice) }
            }
            QuestionStem(question: q)
            // Original order with the official answer marked; nothing to pick here.
            OrderedOptions(question: q, order: .original, state: { state($0, q) }, tag: { tag($0, q) }) { _ in }
                .allowsHitTesting(false)
            Button(showsAnswer ? "隱藏答案" : "顯示答案") {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.15)) {
                    answer.toggle(answered: !history.entries.isEmpty, hideByDefault: hideByDefault)
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 48))
            .accessibilityHint(showsAnswer ? "遮住這題的答案與詳解" : "只顯示這題的答案與詳解，不算作答")
            if showsAnswer, let text = AnswerPresentation(question: q, order: .original, chosen: nil).correctionText {
                Text(text)
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice))
            }
            historySection
                .padding(.top, 6)
            if showsAnswer, aiInline {
                aiSection(q)
                    .padding(.top, 4)
            }
            NoteField(question: q, onFocusChange: { f in withAnimation(.easeInOut(duration: 0.2)) { editing = f } })
                .padding(.top, 4)
        }
    }

    /// 一律給分 questions mark the originally published answer; the correction note says everything counts.
    private func accepted(_ q: Question) -> Set<String> {
        q.allCredit ? Set([q.originalAnswer].compactMap { $0 }) : Set(q.answer)
    }

    private func state(_ letter: String, _ q: Question) -> OptionRow.State {
        showsAnswer && accepted(q).contains(letter) ? .correct : .idle
    }

    private func tag(_ letter: String, _ q: Question) -> String {
        guard showsAnswer, accepted(q).contains(letter) else { return "" }
        return q.corrected || q.allCredit ? "給分" : "正確答案"
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("作答紀錄").appFont(14, .bold, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                if let reason = history.latestReason {
                    Text(reason).appFont(12, .medium, relativeTo: .caption1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(Palette.warn)
                        .background(Capsule().fill(Palette.warnSoft))
                        .accessibilityLabel("錯因：\(reason)")
                }
            }
            if history.entries.isEmpty {
                Text("還沒作答").appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.prefix(Self.maxEntries).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                        entryRow(e)
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                if history.entries.count > Self.maxEntries {
                    Text("只列最近 \(Self.maxEntries) 次").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private static let maxEntries = 8

    private func entryRow(_ e: QuestionHistory.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.correct ? "checkmark" : "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(e.correct ? Palette.accent : Palette.warn)
                .frame(width: 18)
            Text(DateText.monthDay.string(from: e.date)).monospacedDigit().foregroundStyle(Palette.muted)
            Text(([e.outcome] + [e.reason].compactMap { $0 }).joined(separator: "・"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appFont(14, relativeTo: .subheadline)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    // MARK: Paging

    private func page(_ offset: Int) {
        let previous = questionID
        guard pager.step(offset) else { return }
        aiUsage.finish(previous)
        if offset < 0 { usageNavigation.previousUsed = true } else { usageNavigation.nextUsed = true }
        Haptics.selection()
        answer.reset()
        aiOpen = false
        aiTrigger = "manual"
        load()
    }

    private var pagingBar: some View {
        HStack(spacing: 10) {
            Button { page(-1) } label: {
                Label("上一題", systemImage: "chevron.left")
            }
            .disabled(!pager.hasPrevious)
            .accessibilityLabel("上一題")
            Button { page(1) } label: {
                HStack(spacing: 6) {
                    Text("下一題")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(!pager.hasNext)
            .accessibilityLabel("下一題")
        }
        .buttonStyle(OutlineButtonStyle(height: 52))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .readableBarWidth()
        .background(Palette.ground.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }
}
