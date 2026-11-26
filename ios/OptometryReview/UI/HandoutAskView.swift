import SwiftUI

// 問講義: ask the AI about one handout or one 考點. Conversations stay on this device (Model/HandoutAsk.swift).

struct HandoutAskRoute: Hashable, Identifiable {
    let unitID: String
    var pointID: String?
    var id: String { HandoutAskRules.key(unit: unitID, pointID: pointID) }
}

/// 「問這份講義」/「問這個考點」 button. In Release it is hidden without an AI key; Debug shows it disabled.
struct HandoutAskEntry: View {
    let title: String
    let action: () -> Void

    var body: some View {
        let configured = HandoutAsker.shared?.isConfigured ?? false
        #if DEBUG
        let show = true
        #else
        let show = configured
        #endif
        if show {
            Button {
                Haptics.selection()
                action()
            } label: {
                Label(configured ? title : "\(title)（AI 未設定）", systemImage: "text.bubble")
                    .labelStyle(.titleAndIcon)
                    .appFont(16, .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(configured ? Palette.accent : Palette.muted)
                    .background(RoundedRectangle(cornerRadius: 14).fill(configured ? Palette.accentSoft : Palette.badge))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!configured)
            .accessibilityHint(configured ? "AI 產生的回答，請對照課本" : "")
        }
    }
}

struct HandoutAskView: View {
    let route: HandoutAskRoute
    var backLabel = "返回重點講義"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.questionBank) private var bank
    @State private var input = ""
    @State private var confirmStartOver = false
    @State private var contextOpen = true
    @State private var didSetup = false
    #if DEBUG
    /// `-askPrefill "q1|q2|…"`: the field is refilled with the next question after each send (simulator walkthroughs;
    /// the simulator cannot type Chinese or paste reliably).
    @State private var debugQueue = DebugLaunch.askPrefill
    #endif

    private var asker: HandoutAsker? { HandoutAsker.shared }
    private var key: String { route.id }
    private var turns: [AIChatTurn] { asker?.turns(key) ?? [] }
    private var pending: String? { asker?.pending[key] }
    private var failure: (error: AIError, question: String)? { asker?.failure[key] }
    private var isFull: Bool { HandoutAskRules.isFull(turns) }
    private var wholeHandout: Bool { route.pointID == nil }

    private var handoutTitle: String { bank.learning.handouts[route.unitID]?.title ?? bank.unitByID[route.unitID]?.name ?? "" }
    private var pointLabel: String? {
        route.pointID.flatMap { bank.learning.pointByID[$0] }.map { "考點 \($0.number)・\($0.title)" }
    }
    private var contextTitle: String { pointLabel ?? handoutTitle }
    private var contextBlocks: [HandoutBlock] {
        guard let handout = bank.learning.handouts[route.unitID] else { return [] }
        if let pid = route.pointID {
            if let hp = handout.points.first(where: { $0.id == pid }) { return hp.blocks }
            return bank.learning.pointByID[pid].map { [.paragraph($0.summary)] } ?? []
        }
        return handout.intro
    }
    private var contextRefs: [String: String] { bank.learning.handouts[route.unitID]?.refs ?? [:] }
    private var placeholder: String { wholeHandout ? "問這份講義…" : "問這個考點…" }

    var body: some View {
        GeometryReader { geo in
            let wide = Layout.isWideAnswerLayout(geo.size)
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(contextTitle).appFont(21, .bold).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                HandoutBlocksView(blocks: contextBlocks, refs: contextRefs, onRef: { _ in })
                            }
                            .padding(20)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                        }
                        Rectangle().fill(Palette.border).frame(width: 1).ignoresSafeArea(edges: .bottom)
                        chatColumn(wide: true).frame(width: 500)
                    }
                } else {
                    chatColumn(wide: false)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: backLabel) { dismiss() }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("handoutAsk")
        .tint(Palette.accent)
        .onChange(of: failure?.question) { _, failed in
            if let failed, input.isEmpty { input = failed }
        }
        .onChange(of: turns.count) { old, new in
            // The first answer collapses the handout card; tapping it opens it again.
            if old == 0, new > 0 { withAnimation(.easeInOut(duration: 0.25)) { contextOpen = false } }
        }
        .onAppear {
            asker?.dismissFailure(key)
            if !didSetup {
                didSetup = true
                contextOpen = turns.isEmpty
            }
            #if DEBUG
            if input.isEmpty, !debugQueue.isEmpty { input = debugQueue.removeFirst() }
            #endif
        }
        .alert("重新開始？", isPresented: $confirmStartOver) {
            Button("取消", role: .cancel) {}
            Button("重新開始", role: .destructive) { asker?.startOver(key) }
        } message: {
            Text("這段對話會從這支手機清掉，不能復原。")
        }
    }

    private func chatColumn(wide: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    chatHeader
                    if !wide { contextCard }
                    if turns.isEmpty && pending == nil {
                        Text(wholeHandout ? "不懂的地方、想比較的觀念，都可以問。AI 會依這份講義的內容回答。"
                                          : "這個考點哪裡不清楚？AI 會依這個考點的講義內容回答。")
                            .appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        if turn.role == .user {
                            ChatBubble(text: turn.text, mine: true)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Chip(text: "AI 產生，請對照課本", kind: .notice)
                                ChatBubble(text: turn.text, mine: false, rich: true)
                            }
                        }
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
                        Label(failure.error.message, systemImage: "exclamationmark.circle")
                            .appFont(14, relativeTo: .subheadline)
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.warnSoft))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .readableScrollWidth()
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if !turns.isEmpty { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: turns.count) { scrollToEnd(proxy) }
            .onChange(of: pending) { scrollToEnd(proxy) }
            .onChange(of: failure?.question) { scrollToEnd(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(wide: wide) }
    }

    /// Compact header: what is being asked about, and the AI label.
    private var chatHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(wholeHandout ? "問這份講義" : "問這個考點").appFont(20, .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
            }
            Text("每段對話最多 \(HandoutAskRules.maxRounds) 輪 ・ 對話只存在這支手機")
                .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
        }
    }

    /// The asked content: the point's section, or the handout's title and 一眼看懂. Open before the first
    /// question, folded after the first answer; long content scrolls inside.
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.25)) { contextOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let unit = bank.unitByID[route.unitID] {
                            Text(unit.name).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                        }
                        Text(contextTitle).appFont(15, .bold).multilineTextAlignment(.leading)
                        if !contextOpen {
                            Text("點一下看講義內容").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted).rotationEffect(.degrees(contextOpen ? 180 : 0))
                }
                .padding(14)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("講義內容：\(contextTitle)")
            .accessibilityValue(contextOpen ? "已展開" : "已收合")
            .accessibilityAddTraits(.isButton)
            if contextOpen {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                ScrollView {
                    HandoutBlocksView(blocks: contextBlocks, refs: contextRefs, onRef: { _ in })
                        .padding(14)
                }
                .frame(maxHeight: 300)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border, lineWidth: 1))
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func bottomBar(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if asker == nil || !(asker?.isConfigured ?? false) {
                Text("AI 解析未設定").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 8) {
                    Text(isFull ? "已問滿 \(HandoutAskRules.maxRounds) 輪"
                                : "第 \(min(HandoutAskRules.rounds(turns) + 1, HandoutAskRules.maxRounds))／\(HandoutAskRules.maxRounds) 輪")
                        .appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    if !turns.isEmpty || failure != nil {
                        Button {
                            Haptics.selection()
                            confirmStartOver = true
                        } label: {
                            Label("重新開始", systemImage: "arrow.counterclockwise")
                                .appFont(14, .medium, relativeTo: .subheadline)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .foregroundStyle(Palette.ink)
                                .background(Capsule().fill(Palette.badge))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if isFull {
                    Text("這段對話已問滿 \(HandoutAskRules.maxRounds) 輪；想問別的，按「重新開始」。")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ChatInputRow(placeholder: placeholder, sendLabel: "送出問題", text: $input,
                                 disabled: pending != nil, maxLength: HandoutAskRules.maxQuestion, onSend: send)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .modifier(BarWidth(limited: !wide))
        .background(Palette.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func send() {
        guard let q = HandoutAskRules.normalized(input), pending == nil, !isFull else { return }
        Haptics.selection()
        asker?.ask(unit: route.unitID, pointID: route.pointID, question: q)
        input = ""
        #if DEBUG
        if !debugQueue.isEmpty { input = debugQueue.removeFirst() }
        #endif
    }
}

/// Bottom bar content: the readable column on single-column layouts; in the two-column layout the bar already sits in
/// its own 500 pt column.
private struct BarWidth: ViewModifier {
    let limited: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if limited { content.readableBarWidth() } else { content }
    }
}
