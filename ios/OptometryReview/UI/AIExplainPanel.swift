import SwiftUI
import SwiftData

// 「AI 解析」 trigger and the AI explanation panel shown under an answered question.

extension AIQuestionPayload {
    /// nil when the question cannot be explained from text (options drawn inside a figure) or has no paper.
    static func make(_ q: Question, bank: QuestionBank) -> AIQuestionPayload? {
        guard !q.optionsAsImage,
              !Question.letters.contains(where: { (q.options[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }),
              let serverID = AIQuestionID.make(q, bank: bank) else { return nil }
        return AIQuestionPayload(localID: q.id, serverID: serverID, context: AIQuestionContext(q))
    }
}

extension HandoutRoute: Identifiable {
    var id: String { "\(unitID)#\(pointID ?? "")" }
}

/// In Release the trigger is hidden without a token; Debug shows the disabled setup label.
struct AIExplainButton: View {
    let question: Question
    var height: CGFloat = 52
    var fullWidth = true
    let action: () -> Void

    @Environment(\.questionBank) private var bank

    var body: some View {
        if AIQuestionPayload.make(question, bank: bank) != nil {
            let configured = AIExplainer.shared?.isConfigured ?? false
            #if DEBUG
            let showTrigger = true
            #else
            let showTrigger = configured
            #endif
            if showTrigger {
            Button {
                Haptics.selection()
                action()
            } label: {
                Label(configured ? "AI 解析" : "AI 解析未設定", systemImage: configured ? "text.bubble" : "exclamationmark.circle")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, fullWidth ? 0 : 14)
            }
            .buttonStyle(AITriggerButtonStyle(height: height, fullWidth: fullWidth))
            .disabled(!configured)
            .accessibilityHint(configured ? "AI 產生的解析，請對照課本" : "")
            }
        }
    }
}

private struct AITriggerButtonStyle: ButtonStyle {
    let height: CGFloat
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(16, .bold)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .foregroundStyle(isEnabled ? Palette.accent : Palette.muted)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(isEnabled ? Palette.accent : Palette.border, lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Inline section: an optional 「AI 解析」 trigger, then the panel once opened.
struct AIExplainSection: View {
    let question: Question
    let order: OptionOrder
    @Binding var isOpen: Bool
    /// ORIGINAL letter of the learner's wrong answer to this question; nil when right, revealed or unknown.
    var wrongChoice: String? = nil
    /// Show the inline 「AI 解析」 button while closed (screens with their own button in a bottom sheet pass false).
    var showsTrigger = true
    var trigger = "manual"
    var usage: AIUsageSession? = nil
    var onInputFocus: ((Bool) -> Void)?

    @Environment(\.questionBank) private var bank

    var body: some View {
        if let payload = AIQuestionPayload.make(question, bank: bank), let explainer = AIExplainer.shared {
            Group {
                if isOpen {
                    AIExplainPanel(payload: payload, question: question, order: order, explainer: explainer,
                                   wrongChoice: wrongChoice, trigger: trigger, usage: usage,
                                   onClose: { withAnimation(.easeInOut(duration: 0.2)) { isOpen = false } },
                                   onInputFocus: onInputFocus)
                        .id(question.id)
                        .transition(.opacity)
                } else if showsTrigger {
                    AIExplainButton(question: question, height: 48) {
                        explainer.clearError(question.id)
                        withAnimation(.easeInOut(duration: 0.2)) { isOpen = true }
                    }
                }
            }
        }
    }
}

/// The panel: header and badge, loading / error / text, actions, follow-up thread and input.
struct AIExplainPanel: View {
    let payload: AIQuestionPayload
    let question: Question
    let order: OptionOrder
    let explainer: AIExplainer
    var wrongChoice: String? = nil
    let trigger: String
    let onClose: () -> Void
    var onInputFocus: ((Bool) -> Void)?

    @Environment(\.questionBank) private var bank
    @State private var handoutRoute: HandoutRoute?
    @Query private var cached: [AIExplanation]
    @State private var input = ""
    @State private var showReport = false
    @State private var reportNote = ""
    @Environment(\.scenePhase) private var scenePhase
    let usage: AIUsageSession?
    @State private var localUsage = AIUsageSession()
    @State private var usageOwner = UUID()
    private var sessionUsage: AIUsageSession { usage ?? localUsage }
    @State private var panelVisible = false

    static let maxThread = 6

    init(payload: AIQuestionPayload, question: Question, order: OptionOrder, explainer: AIExplainer,
         wrongChoice: String? = nil, trigger: String = "manual", usage: AIUsageSession? = nil, onClose: @escaping () -> Void, onInputFocus: ((Bool) -> Void)?) {
        self.usage = usage
        self.trigger = trigger
        self.wrongChoice = wrongChoice
        self.payload = payload
        self.question = question
        self.order = order
        self.explainer = explainer
        self.onClose = onClose
        self.onInputFocus = onInputFocus
        let id = payload.localID
        _cached = Query(filter: #Predicate<AIExplanation> { $0.questionID == id })
    }

    private var entry: AIExplanation? { cached.first }
    private var phase: AIExplainer.Phase { explainer.phase(for: payload.localID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if question.hasFigure || !question.figures.isEmpty {
                note("本題有附圖，AI 看不到圖，解析可能不完整", icon: "photo")
            }
            // Explanations with 〔X〕 markers are rewritten to the on-screen letters; older cached ones keep the note.
            if !order.isOriginal, let entry, !AIOptionMarkers.contains(entry.text) {
                note("解析裡的選項代號依原試卷。對照目前畫面：" + mapping, icon: "arrow.left.arrow.right")
            }
            if case .loading = phase { loadingRow }
            if case .failed(let error, let regenerate) = phase { errorRow(error, regenerate: regenerate) }
            if let entry {
                if let line = explainer.chosenNote(for: payload.localID, chosen: wrongChoice) { chosenLine(line) }
                AIExplanationText(text: AIOptionMarkers.map(entry.text, order: order),
                                  onOtherOptions: { sessionUsage.value?.otherOptions = true })
                    .background {
                        UsageReadingProbe { depth, visible in
                            sessionUsage.update(usageOwner, visible: canRead, depth: depth)
                        }
                        .allowsHitTesting(false)
                    }
                    .opacity(explainer.isLoading(payload.localID) ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.2), value: explainer.isLoading(payload.localID))
                pointLink
                actions(entry)
                thread(entry)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .background {
            UsageReadingProbe { _, visible in
                if panelVisible != visible { panelVisible = visible }
                updateReadingClock()
            }
            .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border, lineWidth: 1))
        .onAppear {
            beginReading()
            startIfNeeded()
        }
        .onDisappear(perform: finishReading)
        .onChange(of: scenePhase) { updateReadingClock() }
        .onChange(of: handoutRoute) { updateReadingClock() }
        .onChange(of: showReport) { updateReadingClock() }
        .trackScreen("ai")
        .onChange(of: explainer.followupFailure[payload.localID]?.question) { _, failed in
            if let failed, input.isEmpty { input = failed }
        }
        .sheet(item: $handoutRoute) { route in
            NavigationStack {
                HandoutView(route: route, backLabel: "返回題目").interactivePopEnabled()
            }
        }
        .alert("解析有誤", isPresented: $showReport) {
            TextField("哪裡有誤（選填）", text: $reportNote)
            Button("取消", role: .cancel) { reportNote = "" }
            Button("送出") {
                explainer.reportWrong(payload, note: reportNote)
                reportNote = ""
            }
        } message: {
            Text("送出後會留下紀錄，之後檢查修正。答案仍以考選部公布為準。")
        }
    }

    private var canRead: Bool {
        scenePhase == .active && panelVisible && entry != nil && handoutRoute == nil && !showReport
    }

    private func beginReading() {
        sessionUsage.attach(usageOwner, qid: payload.localID, trigger: trigger, cached: entry != nil)
    }

    private func updateReadingClock() {
        sessionUsage.update(usageOwner, visible: canRead)
    }

    private func finishReading() {
        sessionUsage.detach(usageOwner)
        if usage == nil { sessionUsage.finish() }
    }

    private func close() {
        sessionUsage.finish()
        onClose()
    }

    private func startIfNeeded() {
        if entry == nil {
            guard phase == .idle else { return }
            explainer.explain(payload, chosen: wrongChoice)
        } else if let wrongChoice, explainer.chosenNote(for: payload.localID, chosen: wrongChoice) == nil {
            explainer.loadChosenNote(payload, chosen: wrongChoice)
        }
    }

    /// 「你選了 X：…」 above the explanation, only when she answered this question wrong.
    private func chosenLine(_ text: String) -> some View {
        Text(ChosenNoteText.display(text, order: order))
            .appFont(15, .medium)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.warnSoft))
            .accessibilityLabel(ChosenNoteText.display(text, order: order))
    }

    /// 「這題的考點：〇〇 → 讀講義」 under the explanation.
    @ViewBuilder
    private var pointLink: some View {
        if let pid = bank.learning.pointsOfQuestion[question.id]?.first, let point = bank.learning.pointByID[pid] {
            Button {
                Haptics.selection()
                sessionUsage.value?.handout = true
                handoutRoute = HandoutRoute(unitID: point.unitID, pointID: point.id)
            } label: {
                HStack(spacing: 6) {
                    Text("這題的考點：\(point.title)").appFont(14, relativeTo: .subheadline)
                        .foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                    Text("→ 讀講義").appFont(14, .bold, relativeTo: .subheadline).foregroundStyle(Palette.accent).fixedSize()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("這題的考點：\(point.title)，讀講義")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI 解析").appFont(16, .bold)
            Text("AI 產生，請對照課本")
                .appFont(12, .bold, relativeTo: .caption1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(Palette.noticeInk)
                .background(Capsule().fill(Palette.notice))
                .fixedSize()
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .padding(.trailing, -12)
            .accessibilityLabel("收起 AI 解析")
        }
    }

    private var mapping: String {
        Question.letters.map { "\($0)→\(order.displayedLetter(forOriginal: $0))" }.joined(separator: "、")
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .appFont(12, relativeTo: .caption1)
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var loadingRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("正在請求解析…")
                .appFont(14, relativeTo: .subheadline)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("取消") {
                Haptics.selection()
                explainer.cancel(payload.localID)
                if entry == nil { close() }
            }
            .appFont(15, .bold)
            .foregroundStyle(Palette.accent)
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
        .accessibilityElement(children: .contain)
    }

    private func errorRow(_ error: AIError, regenerate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: "exclamationmark.circle")
                .appFont(14, relativeTo: .subheadline)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
            if error.retryable {
                Button {
                    Haptics.selection()
                    if regenerate { sessionUsage.value?.regenerated = true }
                    explainer.explain(payload, regenerate: regenerate, chosen: wrongChoice)
                } label: {
                    Label("再試一次", systemImage: "arrow.clockwise")
                        .appFont(14, .bold, relativeTo: .subheadline)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .foregroundStyle(Palette.accent)
                        .background(Capsule().strokeBorder(Palette.accent, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.warnSoft))
    }

    private func actions(_ entry: AIExplanation) -> some View {
        let loading = explainer.isLoading(payload.localID)
        let fb = explainer.feedback[payload.localID] ?? .idle
        let reported = entry.reportedWrong || fb == .sent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                smallButton("再解釋一次", icon: "arrow.clockwise", disabled: loading) {
                    sessionUsage.value?.regenerated = true
                    explainer.explain(payload, regenerate: true, chosen: wrongChoice)
                }
                smallButton(reported ? "已回報" : (fb == .sending ? "回報中…" : "解析有誤"),
                            icon: reported ? "checkmark" : "flag", disabled: reported || fb == .sending || loading) {
                    showReport = true
                }
                Spacer(minLength: 0)
            }
            if case .failed(let e) = fb {
                Text("回報沒有送出：\(e.message)")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.warn)
            }
        }
    }

    private func smallButton(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(title, systemImage: icon)
                .appFont(14, .medium, relativeTo: .subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .foregroundStyle(disabled ? Palette.muted : Palette.ink)
                .background(Capsule().fill(Palette.badge))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Follow-up

    @ViewBuilder
    private func thread(_ entry: AIExplanation) -> some View {
        let turns = entry.followups
        let pending = explainer.pendingQuestion[payload.localID]
        let failure = explainer.followupFailure[payload.localID]
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 2)
            // Stored as received (raw markers, original order); only the AI's answers are mapped for display.
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                ChatBubble(text: turn.role == .user ? turn.text : AIOptionMarkers.map(turn.text, order: order), mine: turn.role == .user)
            }
            if let pending {
                ChatBubble(text: pending, mine: true)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("AI 正在回答，約 10–30 秒").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                }
                .padding(.vertical, 4)
            }
            if let failure {
                Text(failure.error.message)
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if turns.count + (pending == nil ? 0 : 2) >= Self.maxThread {
                Text("這題的追問已達三輪上限；想換個說法可按「再解釋一次」")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
            } else {
                ChatInputRow(placeholder: "追問這題…", sendLabel: "送出追問", text: $input, disabled: pending != nil,
                             onFocusChange: onInputFocus, onSend: send)
            }
        }
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Haptics.selection()
        sessionUsage.value?.followupAsked = true
        explainer.ask(payload, question: q, order: order)
        input = ""
    }
}

/// Structured explanations as a headline, a compact 為什麼 list, 其他選項 behind a disclosure and a 記憶點 card;
/// anything else as plain text.
struct AIExplanationText: View {
    let text: String
    var onOtherOptions: (() -> Void)? = nil
    @State private var showOthers = false

    var body: some View {
        if let s = AIStructuredExplanation.parse(text) {
            VStack(alignment: .leading, spacing: 12) {
                Text(s.headline).appFont(17, .bold).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("為什麼").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    ForEach(Array(s.reasons.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("・").foregroundStyle(Palette.accent)
                            Text(line).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                        .appFont(15)
                    }
                }
                if !s.others.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Haptics.selection()
                            onOtherOptions?()
                            withAnimation(.easeInOut(duration: 0.2)) { showOthers.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text("其他選項").appFont(15, .bold)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .rotationEffect(.degrees(showOthers ? 90 : 0))
                            }
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showOthers ? "已展開" : "已收合")
                        if showOthers {
                            ForEach(Array(s.others.enumerated()), id: \.offset) { _, line in
                                Text(line).appFont(15).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.top, -8)
                }
                if let memory = s.memory {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("記憶點").appFont(12, .bold, relativeTo: .caption1).foregroundStyle(Palette.noticeInk)
                        Text(memory).appFont(15).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice))
                }
            }
            .textSelection(.enabled)
        } else {
            Text(text)
                .appFont(16)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
