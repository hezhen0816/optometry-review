import SwiftUI
import SwiftData

// MARK: - Rich text

enum HandoutText {
    static let scheme = "optoref"

    /// `**bold**` runs and, when `link` is set, question refs as tappable links carrying the question id.
    static func attributed(_ text: String, refs: [String: String], link: Bool = true) -> AttributedString {
        var result = AttributedString()
        for (i, part) in text.components(separatedBy: "**").enumerated() where !part.isEmpty {
            var seg = AttributedString(part)
            if i % 2 == 1 { seg.inlinePresentationIntent = .stronglyEmphasized }
            if link {
                var cursor = seg.startIndex
                for ref in HandoutRefs.all(in: part) {
                    guard let qid = refs[ref], let r = seg[cursor...].range(of: ref),
                          let enc = qid.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                          let url = URL(string: "\(scheme)://q?id=\(enc)") else { continue }
                    seg[r].link = url
                    seg[r].underlineStyle = .single
                    cursor = r.upperBound
                }
            }
            result += seg
        }
        return result
    }

    static func questionID(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}

/// Text with inline refs, plus trailing refs as separate 44 pt buttons.
private struct HandoutTextView: View {
    let text: String
    let refs: [String: String]
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    let onRef: (String) -> Void

    var body: some View {
        let split = HandoutRefs.splitTrailing(text)
        VStack(alignment: .leading, spacing: 2) {
            if !split.body.isEmpty {
                Text(HandoutText.attributed(split.body, refs: refs))
                    .appFont(size, weight)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !split.refs.isEmpty {
                RefButtons(refs: Array(NSOrderedSet(array: split.refs)) as? [String] ?? split.refs, map: refs, onRef: onRef)
            }
        }
    }
}

/// Wrapping row of 「106111 #2」 buttons, each at least 44 pt tall.
private struct RefButtons: View {
    let refs: [String]
    let map: [String: String]
    let onRef: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 0) {
            ForEach(refs, id: \.self) { ref in
                if let qid = map[ref] {
                    Button {
                        Haptics.selection()
                        onRef(qid)
                    } label: {
                        Text(ref).appFont(14, .bold, relativeTo: .subheadline).monospacedDigit()
                            .foregroundStyle(Palette.accent)
                            .padding(.trailing, 14)
                            .padding(.top, 4)
                            .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("開啟題目 \(ref)")
                } else {
                    Text(ref).appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                        .padding(.trailing, 14).padding(.top, 4).frame(minHeight: 44, alignment: .topLeading)
                }
            }
        }
    }
}

// MARK: - Blocks

struct HandoutBlocksView: View {
    let blocks: [HandoutBlock]
    let refs: [String: String]
    let onRef: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: HandoutBlock) -> some View {
        switch block {
        case .paragraph(let text):
            HandoutTextView(text: text, refs: refs, onRef: onRef)
        case .heading(let text):
            Text(text).appFont(16, .bold).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let items):
            HandoutListView(items: items, ordered: ordered, level: 0, refs: refs, onRef: onRef)
        case .quote(let lines):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Palette.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(HandoutText.attributed(line, refs: refs, link: false)).appFont(13, relativeTo: .footnote)
                            .foregroundStyle(Palette.muted).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            HandoutTable(header: header, rows: rows, refs: refs, onRef: onRef)
        case .unknown:
            EmptyView()
        }
    }
}

private struct HandoutListView: View {
    let items: [HandoutItem]
    let ordered: Bool
    let level: Int
    let refs: [String: String]
    let onRef: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(ordered ? "\(i + 1)." : (level == 0 ? "•" : "–"))
                        .appFont(15).monospacedDigit().foregroundStyle(Palette.muted)
                        .frame(minWidth: 16, alignment: .trailing)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HandoutTextView(text: item.text, refs: refs, onRef: onRef)
                        if let children = item.children, !children.isEmpty {
                            HandoutListView(items: children, ordered: false, level: level + 1, refs: refs, onRef: onRef)
                        }
                    }
                }
            }
        }
    }
}

private struct TableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Table that scrolls sideways when its columns cannot keep a readable width on the screen.
private struct HandoutTable: View {
    let header: [String]
    let rows: [[String]]
    let refs: [String: String]
    let onRef: (String) -> Void

    @State private var available: CGFloat = 0
    private static let minColumn: CGFloat = 84

    /// Natural column width from the longest text, within a readable range.
    private func natural(_ col: Int) -> CGFloat {
        let cells = ([header] + rows).compactMap { $0.indices.contains(col) ? $0[col] : nil }
        let longest = cells.map { HandoutRefs.splitTrailing($0).body.count }.max() ?? 4
        return min(240, max(Self.minColumn, CGFloat(longest) * 15 + 24))
    }

    /// Fits the screen when every column can keep its minimum width; otherwise scrolls sideways.
    /// Widths never add up to more than the room, so the table cannot widen the page.
    private func layout() -> (widths: [CGFloat], scrolls: Bool) {
        let nat = header.indices.map(natural)
        guard available > 0 else { return (nat, false) }
        let total = nat.reduce(0, +)
        // Room to spare (iPad): widen every column in proportion so the table fills the card.
        if total <= available { return (nat.map { floor($0 * available / total) }, false) }
        if CGFloat(nat.count) * Self.minColumn > available { return (nat, true) }
        // Shrink in proportion to the natural width; columns that would go below the minimum stay at it.
        var widths = nat
        var fixed = Set<Int>()
        while true {
            let freeIdx = nat.indices.filter { !fixed.contains($0) }
            let room = available - CGFloat(fixed.count) * Self.minColumn
            let scale = room / freeIdx.map { nat[$0] }.reduce(0, +)
            var changed = false
            for i in freeIdx where nat[i] * scale < Self.minColumn {
                fixed.insert(i)
                changed = true
            }
            if !changed {
                for i in nat.indices { widths[i] = fixed.contains(i) ? Self.minColumn : nat[i] * scale }
                break
            }
        }
        return (widths.map { floor($0) }, false)
    }

    var body: some View {
        let l = layout()
        VStack(alignment: .leading, spacing: 0) {
            // Measures the room the table gets, independent of the table's own (possibly wider) size.
            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TableWidthKey.self, value: geo.size.width)
                })
            if available > 0 {
                Group {
                    if l.scrolls {
                        ScrollView(.horizontal, showsIndicators: true) { grid(l.widths) }
                    } else {
                        grid(l.widths)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onPreferenceChange(TableWidthKey.self) { available = $0 }
    }

    private func grid(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(header, widths, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(Palette.hairline).frame(height: 1)
                row(r, widths, isHeader: false)
            }
        }
    }

    private func row(_ cells: [String], _ widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { i in
                HandoutTextView(text: cells.indices.contains(i) ? cells[i] : "", refs: refs,
                                size: 14, weight: isHeader ? .bold : .regular, onRef: onRef)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: widths[i], alignment: .topLeading)
            }
        }
        .background(isHeader ? Palette.accentSoft : Color.clear)
    }
}

// MARK: - 講義頁

/// 重點講義 of one unit: 一眼看懂, collapsible 考點 cards with the learner's numbers, 易錯陷阱, self-quiz.
struct HandoutView: View {
    let route: HandoutRoute
    var backLabel = "返回單元"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(YearFilterStore.key(.units)) private var yearsRaw = ""
    @State private var stats: [String: PointStat] = [:]
    @State private var expanded: Set<String> = []
    @State private var revealed: Set<Int> = []
    @State private var didSetup = false
    @State private var practice: SessionRequest?
    @State private var aiPractice: AIPracticeRequest?
    @State private var detail: QuestionDetailRoute?
    @State private var askRoute: HandoutAskRoute?
    /// Wrong answers per question id (看解答 included), for the iPad 「你在這個考點」 panel.
    @State private var wrongCounts: [String: Int] = [:]
    /// What the iPad center column shows.
    @State private var padSection: PadSection = .intro
    @State private var width: CGFloat = 0

    private enum PadSection: Hashable {
        case intro, point(String), extra(Int)
    }

    /// iPad landscape (design LearnHandoutPad): 考點 index | one section | 你在這個考點. Narrower windows stack like the iPhone.
    private var threeColumns: Bool { width >= Layout.threeColumnWidth && handout != nil }

    private var unit: ConceptUnit? { bank.unitByID[route.unitID] }
    private var handout: Handout? { bank.learning.handouts[route.unitID] }
    private var points: [StudyPoint] { bank.learning.points(of: route.unitID) }

    private var scopeQuestions: [Question] {
        let years = YearFilterStore.decode(yearsRaw)
        return bank.reviewPool(includeSpecial: includeSpecial).filter { years.contains($0.year) }
    }

    /// Newest paper first, like the unit page list.
    private func ordered(_ qs: [Question]) -> [Question] {
        qs.sorted { ($1.year, $1.code, $0.number) < ($0.year, $0.code, $1.number) }
    }

    private var unitQuestions: [Question] {
        ordered(scopeQuestions.filter { $0.primaryConcept == route.unitID })
    }

    private func pointQuestions(_ id: String) -> [Question] {
        let ids = Set(bank.learning.questionsOfPoint[id] ?? [])
        return ordered(scopeQuestions.filter { ids.contains($0.id) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if threeColumns, let handout { padColumns(handout) } else { stacked }
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
            .foregroundStyle(Palette.ink)
            .background(Palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .trackScreen("handout")
            .firstVisitTip(key: SettingsKey.tipHandoutShown, eligible: handout != nil,
                           title: threeColumns ? "點考點看內容" : "點考點展開",
                           message: "每個考點有重點整理、易錯陷阱和「練這個考點」。做過幾題後，考點最上方會多一張「你的筆記」：AI 依你的作答寫的補救重點，請對照課本。")
            .tint(Palette.accent)
            .environment(\.openURL, OpenURLAction { url in
                guard let id = HandoutText.questionID(from: url) else { return .systemAction }
                openQuestion(id)
                return .handled
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { load(proxy: proxy) }
            .onChange(of: includeSpecial) { reloadStats() }
            .onChange(of: yearsRaw) { reloadStats() }
            .onChange(of: practice) { _, req in if req == nil { reloadStats() } }
            .fullScreenCover(item: $aiPractice, onDismiss: reloadStats) { AIPracticeView(request: $0) }
            .navigationDestination(item: $practice) { req in
                ReviewSessionView(request: req, pushed: true, backLabel: "返回重點講義", listSource: "unit")
            }
            .navigationDestination(item: $detail) { QuestionDetailView(route: $0) }
            .navigationDestination(item: $askRoute) { HandoutAskView(route: $0) }
        }
    }

    /// iPhone, and iPad portrait: everything in one column of collapsible cards.
    private var stacked: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let handout {
                    header(handout)
                    if !handout.intro.isEmpty { HandoutIntroSection(handout: handout, onRef: openQuestion) }
                    ForEach(points) { point in pointCard(point, handout: handout) }
                    ForEach(Array(handout.extras.enumerated()), id: \.offset) { i, extra in
                        extraCard(extra, id: "extra\(i)", handout: handout)
                    }
                    if !handout.quizItems.isEmpty { HandoutQuizSection(handout: handout, revealed: $revealed, reduceMotion: reduceMotion) }
                    unitPracticeButton
                } else {
                    Text("這個單元還沒有重點講義").appFont(15).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            // Children never get to widen the page: the content is exactly the screen width minus the margins
            // (centered, at most the readable width, on iPad).
            .containerRelativeFrame(.horizontal) { width, _ in min(width, Layout.readableWidth(for: width)) - 40 }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
    }

    private var unitPracticeButton: some View {
        let n = unitQuestions.count
        return Button("練這個單元 \(n) 題") { start(unitQuestions) }
            .buttonStyle(PrimaryButtonStyle(height: 52))
            .monospacedDigit()
            .disabled(n == 0)
    }

    // MARK: iPad columns

    private func padColumns(_ handout: Handout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { padIndex(handout).padding(.horizontal, 14).padding(.vertical, 12) }
                .frame(width: 280)
                .background(Palette.card)
            Rectangle().fill(Palette.border).frame(width: 1).ignoresSafeArea(edges: .bottom)
            ScrollViewReader { columnProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(handout).id("top")
                        padCenter(handout)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: padSection) { columnProxy.scrollTo("top", anchor: .top) }
            }
            ScrollView { padSide(handout).padding(.trailing, 20).padding(.vertical, 12) }
                .frame(width: 300)
        }
    }

    private func padIndex(_ handout: Handout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("考點 ・ 點一下看那段").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                .padding(.horizontal, 10).padding(.bottom, 6)
            if !handout.intro.isEmpty {
                HandoutIndexRow(selected: padSection == .intro, action: { padSection = .intro }) {
                    padIndexIcon("eye")
                } title: {
                    Text("一眼看懂").appFont(14, padSection == .intro ? .bold : .medium, relativeTo: .subheadline)
                } trailing: { EmptyView() }
            }
            HandoutPointList(points: points, stats: stats, selected: {
                if case .point(let id) = padSection { return id } else { return nil }
            }()) { padSection = .point($0.id) }
            ForEach(Array(handout.extras.enumerated()), id: \.offset) { i, extra in
                HandoutIndexRow(selected: padSection == .extra(i), action: { padSection = .extra(i) }) {
                    padIndexIcon("exclamationmark.triangle", tint: Palette.warn)
                } title: {
                    Text(extra.heading).appFont(14, padSection == .extra(i) ? .bold : .medium, relativeTo: .subheadline)
                } trailing: { EmptyView() }
            }
        }
    }

    private func padIndexIcon(_ name: String, tint: Color = Palette.accent) -> some View {
        Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func padCenter(_ handout: Handout) -> some View {
        switch padSection {
        case .intro:
            HandoutIntroSection(handout: handout, onRef: openQuestion)
        case .point(let id):
            if let point = points.first(where: { $0.id == id }) {
                HandoutPointSection(point: point, stat: stats[id], handout: handout, questionCount: 0,
                                    expanded: true, onToggle: {}, onRef: openQuestion, onPractice: {}, inColumn: true,
                                    note: InsightsStore.shared.note(for: point.id),
                                    onAsk: { askRoute = HandoutAskRoute(unitID: route.unitID, pointID: point.id) })
            }
        case .extra(let i):
            if handout.extras.indices.contains(i) {
                let extra = handout.extras[i]
                VStack(alignment: .leading, spacing: 12) {
                    Text(extra.heading).appFont(21, .bold).foregroundStyle(Palette.warn)
                        .accessibilityAddTraits(.isHeader)
                    HandoutBlocksView(blocks: extra.blocks, refs: handout.refs, onRef: openQuestion)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            }
        }
    }

    private func padSide(_ handout: Handout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .point(let id) = padSection {
                let qs = pointQuestions(id)
                pointStatusPanel(stats[id], questions: qs)
                Button("練這個考點 \(qs.count) 題") { start(qs) }
                    .buttonStyle(PrimaryButtonStyle(height: 48))
                    .monospacedDigit()
                    .disabled(qs.isEmpty)
                let aiN = bank.ai.questions(point: id).count
                if aiN > 0 {
                    Button("練 AI 題 \(aiN)") { startAI(id) }
                        .buttonStyle(SecondaryButtonStyle(height: 48))
                        .monospacedDigit()
                }
            } else {
                unitPracticeButton
            }
            if !handout.quizItems.isEmpty { HandoutQuizSection(handout: handout, revealed: $revealed, reduceMotion: reduceMotion) }
        }
    }

    /// 「你在這個考點」: counts and the questions of the point answered wrong, most mistakes first.
    private func pointStatusPanel(_ stat: PointStat?, questions: [Question]) -> some View {
        let wrong = questions.filter { (wrongCounts[$0.id] ?? 0) > 0 }
            .sorted { (wrongCounts[$0.id] ?? 0) > (wrongCounts[$1.id] ?? 0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("你在這個考點").appFont(15, .bold).accessibilityAddTraits(.isHeader)
            Group {
                if let stat, stat.answers > 0 {
                    Text(wrong.isEmpty ? "\(stat.countsText) ・ 都答對了" : "\(stat.countsText) ・ 下面是答錯的題")
                } else {
                    Text("還沒做過這個考點的題目")
                }
            }
            .appFont(13, relativeTo: .footnote).monospacedDigit().foregroundStyle(Palette.muted)
            .padding(.bottom, 4)
            ForEach(wrong.prefix(8)) { q in
                Button {
                    Haptics.selection()
                    detail = QuestionDetailRoute(entry: "handout", id: q.id, ids: wrong.map(\.id), backLabel: "返回重點講義")
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(q.sourceLabel).foregroundStyle(Palette.muted)
                            Spacer()
                            Text("錯 \(wrongCounts[q.id] ?? 0) 次").bold().foregroundStyle(Palette.warn)
                        }
                        .appFont(12, relativeTo: .caption1).monospacedDigit()
                        Text(q.stem).appFont(13, relativeTo: .footnote).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    // MARK: Loading

    private func reloadStats() {
        stats = PointStatsLoader.load(context: context, bank: bank, questions: scopeQuestions, points: points)
        var counts: [String: Int] = [:]
        for a in (try? context.fetch(FetchDescriptor<AttemptRecord>())) ?? [] where !a.correct {
            counts[a.questionID, default: 0] += 1
        }
        wrongCounts = counts
    }

    private func load(proxy: ScrollViewProxy) {
        reloadStats()
        guard !didSetup else { return }
        didSetup = true
        let target = route.pointID.flatMap { id in points.first { $0.id == id } }
        let first = target ?? PointMastery.weakest(points.compactMap { stats[$0.id] }, limit: 1).first?.point ?? points.first
        if let first { expanded = [first.id] }
        padSection = (target ?? first).map { .point($0.id) } ?? .intro
        if let target {
            // Wait for the expanded card to lay out before scrolling to it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(target.id, anchor: .top) }
            }
        }
    }

    private func openQuestion(_ id: String) {
        guard bank.byID[id] != nil else { return }
        detail = QuestionDetailRoute(entry: "handout", id: id, ids: [id], backLabel: "返回重點講義")
    }

    private func startAI(_ pointID: String) {
        let qs = AIPractice.ordered(bank.ai.questions(point: pointID), facts: StudyStore(context: context).aiFacts())
        guard !qs.isEmpty else { return }
        Haptics.selection()
        aiPractice = AIPracticeRequest(ids: qs.map(\.id))
    }

    private func start(_ qs: [Question]) {
        guard !qs.isEmpty else { return }
        Haptics.selection()
        practice = SessionRequest(queue: qs.map(\.id), doneBefore: 0, isDaily: false, isCustom: true)
    }

    // MARK: Sections

    private func header(_ h: Handout) -> some View {
        let scope = Set(scopeQuestions.map(\.id))
        let tagged = Set(points.flatMap { bank.learning.questionsOfPoint[$0.id] ?? [] }).filter(scope.contains)
        return VStack(alignment: .leading, spacing: 8) {
            if let unit {
                Text([unit.subject, unit.group].compactMap { $0 }.joined(separator: " ・ "))
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
            }
            Text(h.title).headingFont(25).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Chip(text: "AI 產生，請對照課本", kind: .notice)
                Text("歷屆 \(tagged.count) 題 ・ \(points.count) 個考點 ・ 答案以官方為準")
                    .appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
            }
            HandoutAskEntry(title: "問這份講義") { askRoute = HandoutAskRoute(unitID: route.unitID) }
                .padding(.top, 4)
        }
    }

    private func toggle(_ id: String) {
        Haptics.selection()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func pointCard(_ point: StudyPoint, handout: Handout) -> some View {
        let qs = pointQuestions(point.id)
        return HandoutPointSection(point: point, stat: stats[point.id], handout: handout, questionCount: qs.count,
                                   expanded: expanded.contains(point.id), onToggle: { toggle(point.id) },
                                   onRef: openQuestion, onPractice: { start(qs) },
                                   aiQuestionCount: bank.ai.questions(point: point.id).count,
                                   onPracticeAI: { startAI(point.id) },
                                   note: InsightsStore.shared.note(for: point.id),
                                   tipTarget: point.id == points.first?.id,
                                   onAsk: { askRoute = HandoutAskRoute(unitID: route.unitID, pointID: point.id) })
    }

    private func extraCard(_ extra: HandoutSection, id: String, handout: Handout) -> some View {
        let open = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                    Text(extra.heading).appFont(16, .bold).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted).rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "已展開" : "已收合")
            if open {
                HandoutBlocksView(blocks: extra.blocks, refs: handout.refs, onRef: openQuestion)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

// MARK: - Reusable pieces (iPhone stacks them; an iPad 3-column layout can place them side by side)

/// 「一眼看懂」 card.
struct HandoutIntroSection: View {
    let handout: Handout
    let onRef: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一眼看懂").appFont(15, .bold).foregroundStyle(Palette.accent)
                .accessibilityAddTraits(.isHeader)
            HandoutBlocksView(blocks: handout.intro, refs: handout.refs, onRef: onRef)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.accentSoft))
    }
}

/// Index of the unit's 考點 (iPad left column): number, title, counts, label; the selected row is highlighted.
struct HandoutPointList: View {
    let points: [StudyPoint]
    let stats: [String: PointStat]
    var selected: String?
    let onSelect: (StudyPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(points) { point in
                let stat = stats[point.id]
                HandoutIndexRow(selected: selected == point.id, action: { onSelect(point) }) {
                    PointNumber(number: point.number)
                } title: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(point.title).appFont(14, selected == point.id ? .bold : .medium, relativeTo: .subheadline)
                        if let stat {
                            Text(stat.answers == 0 ? "歷屆 \(stat.questions) 題 ・ 沒做過" : "歷屆 \(stat.questions) 題 ・ \(stat.countsText)")
                                .appFont(11, relativeTo: .caption2).monospacedDigit().foregroundStyle(Palette.muted)
                        }
                    }
                } trailing: {
                    if let stat { PointLabelChip(label: stat.label) }
                }
                .accessibilityLabel("考點 \(point.number)，\(point.title)，\(stat?.label.title ?? "")")
                .background { if point.id == points.first?.id { Color.clear.coachTarget() } }
            }
        }
    }
}

/// One row of the iPad 講義 index; at least 52 pt tall.
struct HandoutIndexRow<Leading: View, Title: View, Trailing: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let title: Title
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                leading
                title.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 「你在這個考點錯 x 題（做 y 題）」; empty without wrong answers. An orange strip on iPhone, usable as a side panel.
struct HandoutPointStatusView: View {
    let stat: PointStat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stat, stat.wrong > 0 {
                Text("你在這個考點錯 \(stat.wrong) 題（做 \(stat.answers) 題）")
                    .appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.warn)
                    .monospacedDigit()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.warnSoft))
            }
            if let stat, stat.ai.answers > 0 {
                HStack(spacing: 8) {
                    Text("AI 題").appFont(11, .bold, relativeTo: .caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Palette.noticeInk)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.notice))
                    Text("非官方 ・ \(stat.ai.countsText)").appFont(13, relativeTo: .footnote).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    InfoButton(title: "掌握度怎麼算",
                               text: "掌握度看歷屆和 AI 題合計；歷屆正確率、及格推估只算歷屆題。")
                        .frame(width: 32, height: 32)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// One collapsible 考點 card: header, status strip, blocks with refs, 「練這個考點 N 題」. Expansion state comes from outside.
struct HandoutPointSection: View {
    let point: StudyPoint
    let stat: PointStat?
    let handout: Handout
    let questionCount: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onRef: (String) -> Void
    let onPractice: () -> Void
    /// AI questions tagged with the point, and 「練 AI 題」.
    var aiQuestionCount = 0
    var onPracticeAI: () -> Void = {}
    /// iPad columns: always open, no chevron; status and 練這個考點 live in the side panel instead.
    var inColumn = false
    /// 「你的筆記」 from the nightly analysis or 檢討這回; nil hides the card.
    var note: InsightNote? = nil
    /// The first-visit tip points at this card's header.
    var tipTarget = false
    /// 「問這個考點」; nil hides the button.
    var onAsk: (() -> Void)? = nil

    var body: some View {
        let count = stat?.questions ?? questionCount
        return VStack(alignment: .leading, spacing: 0) {
            if inColumn {
                HStack(alignment: .top, spacing: 10) {
                    PointNumber(number: point.number)
                    Text(point.title).appFont(21, .bold).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    if let stat { PointLabelChip(label: stat.label) }
                }
                .padding(20)
                .padding(.bottom, -8)
                if let note {
                    HandoutNoteCard(note: note, answerCount: stat?.answers, pointID: point.id)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
                HandoutBlocksView(blocks: handout.points.first(where: { $0.id == point.id })?.blocks ?? [.paragraph(point.summary)],
                                  refs: handout.refs, onRef: onRef)
                    .padding(.horizontal, 20)
                    .padding(.bottom, onAsk == nil ? 20 : 12)
                if let onAsk {
                    HandoutAskEntry(title: "問這個考點", action: onAsk)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
            } else {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 10) {
                        PointNumber(number: point.number)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.title).appFont(16, .bold).multilineTextAlignment(.leading)
                            HStack(spacing: 8) {
                                Text("歷屆 \(count) 題").appFont(12, relativeTo: .caption1)
                                    .monospacedDigit().foregroundStyle(Palette.muted)
                                if let stat { PointLabelChip(label: stat.label) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.muted).rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(16)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background { if tipTarget { Color.clear.coachTarget() } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("考點 \(point.number)，\(point.title)，歷屆 \(count) 題，\(stat?.label.title ?? "")")
                .accessibilityValue(expanded ? "已展開" : "已收合")
                .accessibilityAddTraits(.isButton)
                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        if let note { HandoutNoteCard(note: note, answerCount: stat?.answers, pointID: point.id) }
                        HandoutPointStatusView(stat: stat)
                        if let hp = handout.points.first(where: { $0.id == point.id }) {
                            HandoutBlocksView(blocks: hp.blocks, refs: handout.refs, onRef: onRef)
                        } else {
                            Text(point.summary).appFont(15).lineSpacing(5)
                        }
                        if aiQuestionCount > 0 {
                            HStack(spacing: 8) {
                                Button("練歷屆題 \(questionCount)", action: onPractice)
                                    .buttonStyle(SecondaryButtonStyle(height: 48))
                                    .disabled(questionCount == 0)
                                Button("練 AI 題 \(aiQuestionCount)", action: onPracticeAI)
                                    .buttonStyle(SecondaryButtonStyle(height: 48))
                            }
                            .monospacedDigit()
                        } else {
                            Button("練這個考點 \(questionCount) 題", action: onPractice)
                                .buttonStyle(SecondaryButtonStyle(height: 48))
                                .monospacedDigit()
                                .disabled(questionCount == 0)
                        }
                        if let onAsk { HandoutAskEntry(title: "問這個考點", action: onAsk) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .id(point.id)
    }
}

/// 「自我小測」: answers stay hidden until 「顯示答案」; the revealed set lives in the caller.
struct HandoutQuizSection: View {
    let handout: Handout
    @Binding var revealed: Set<Int>
    var reduceMotion = false

    var body: some View {
        let items = handout.quizItems
        VStack(alignment: .leading, spacing: 12) {
            Text("自我小測").appFont(16, .bold).accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(i + 1). \(item.question)").appFont(15).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if revealed.contains(i) {
                        Text(HandoutText.attributed(item.answer, refs: handout.refs, link: false)).appFont(15, .bold)
                            .foregroundStyle(Palette.accent).lineSpacing(4)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentSoft))
                    }
                    Button {
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            if revealed.contains(i) { revealed.remove(i) } else { revealed.insert(i) }
                        }
                    } label: {
                        Text(revealed.contains(i) ? "隱藏答案" : "顯示答案").appFont(14, .bold, relativeTo: .subheadline)
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if i < items.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}
