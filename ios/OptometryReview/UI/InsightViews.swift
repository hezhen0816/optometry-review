import SwiftUI

// 學習版第二批 screens: 「你的筆記」 on the handout, 「這輪錯在這些考點」 on the completion screen, and 檢討這回.

// MARK: - Inline Markdown

enum InlineMarkdown {
    /// Inline styles only (bold, italic, code); falls back to plain text.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    struct Line: Equatable {
        let bullet: Bool
        let text: String
    }

    /// The lines of a `fix` text: list markers become bullets, table rows become plain lines, rules disappear.
    static func lines(_ text: String) -> [Line] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("|") {
                let cells = s.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return nil }
                return Line(bullet: false, text: cells.joined(separator: " ｜ "))
            }
            for marker in ["- ", "* ", "• ", "・"] where s.hasPrefix(marker) {
                s = String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return Line(bullet: true, text: s)
            }
            if let m = s.firstMatch(of: /^\d+[.、)）]\s*/) { return Line(bullet: true, text: String(s[m.range.upperBound...])) }
            return Line(bullet: false, text: s)
        }
    }
}

// MARK: - 你的筆記 (handout)

/// 「收藏這份筆記」 / 「已收藏」.
struct SaveNoteButton: View {
    let saved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(saved ? "已收藏" : "收藏這份筆記", systemImage: saved ? "star.fill" : "star")
                .appFont(13, .medium, relativeTo: .footnote)
                .foregroundStyle(saved ? Palette.warn : Palette.accent)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saved)
        .accessibilityLabel(saved ? "已收藏這份筆記" : "收藏這份筆記")
    }
}

/// Top of an expanded 考點 on the handout: what she probably mixes up and what to fix (AI generated).
struct HandoutNoteCard: View {
    let note: InsightNote
    /// Answers the analysis is based on (her answers on this point); nil hides the count.
    let answerCount: Int?
    /// With a point id the card offers 「收藏這份筆記」.
    var pointID: String? = nil
    var source = SavedNotes.nightly
    var questionIDs: [String] = []
    /// Read-only view of a saved note: the footer says when it was saved and there is no save button.
    var savedOn: Date? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @State private var saved = false

    private var footer: String {
        let day = note.at.map { DateText.monthDay.string(from: $0) }
        if let savedOn {
            return ["收藏於 \(DateText.fullDate.string(from: savedOn))", day.map { "筆記產生於 \($0)" }].compactMap { $0 }.joined(separator: " ・ ")
        }
        let basis = answerCount.map { $0 > 0 ? "依你最近 \($0) 次作答分析" : "依你的作答分析" } ?? "依你的作答分析"
        return [basis, day].compactMap { $0 }.joined(separator: " ・ ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("你的筆記").appFont(15, .bold).accessibilityAddTraits(.isHeader)
                Chip(text: "AI 產生，請對照課本", kind: .notice).fixedSize()
                Spacer(minLength: 0)
            }
            if !note.misconception.isEmpty {
                Text(InlineMarkdown.attributed(note.misconception)).appFont(15).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let lines = InlineMarkdown.lines(note.fix)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("補救重點").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if line.bullet { Text("・").foregroundStyle(Palette.accent) }
                            Text(InlineMarkdown.attributed(line.text)).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .appFont(15)
                    }
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text(footer).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let pointID, savedOn == nil {
                    SaveNoteButton(saved: saved) {
                        Haptics.selection()
                        SavedNotes.save(context: context, bank: bank, pointID: pointID, note: note, source: source,
                                        questionIDs: questionIDs)
                        withAnimation(.easeInOut(duration: 0.15)) { saved = true }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.notice.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .onAppear { if let pointID { saved = SavedNotes.isSaved(context: context, pointID: pointID, note: note) } }
    }
}

// MARK: - 這輪錯在這些考點 (completion)

/// Counts of the round's wrong or guessed questions by 考點.
struct SessionWeakPointsCard: View {
    let groups: [ReviewGroup]
    @Environment(\.questionBank) private var bank

    private static let shown = 3

    private func title(_ g: ReviewGroup) -> String {
        bank.learning.pointByID[g.pointID]?.title ?? "其他題目"
    }

    var body: some View {
        let rest = groups.dropFirst(Self.shown)
        VStack(alignment: .leading, spacing: 8) {
            Text("這輪錯在這些考點").appFont(15, .bold).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups.prefix(Self.shown)) { g in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title(g)).appFont(15).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text("\(g.items.count) 題").appFont(14, .bold, relativeTo: .subheadline).monospacedDigit()
                            .foregroundStyle(Palette.warn)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !rest.isEmpty {
                    Text("另外 \(rest.count) 個考點 \(rest.reduce(0) { $0 + $1.items.count }) 題")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

// MARK: - 檢討這回

/// Result of the AI part of the page.
enum RoundReviewState: Equatable {
    case loading
    case loaded(ReviewResult)
    case failed(WeakAnalysisError)
}

/// A question row of 檢討這回, from the server's group or (while loading, or when the server has no group) the session.
private struct ReviewRow: Identifiable {
    let qid: String
    let chosen: String
    let correct: Bool
    let answer: [String]
    let line: String?
    var id: String { qid }
}

private struct ReviewDisplayGroup: Identifiable {
    let pointID: String
    let title: String?
    let note: InsightNote?
    let rows: [ReviewRow]
    var id: String { pointID }
}

/// 檢討這回: what she probably mixed up (AI), then the round's wrong or guessed questions grouped by 考點.
struct RoundReviewView: View {
    /// First answers of the round, in order.
    let answers: [RoundAnswer]
    var backLabel = "返回這輪練習"
    let onClose: () -> Void

    @Environment(\.questionBank) private var bank
    @State private var state: RoundReviewState = .loading
    @State private var task: Task<Void, Never>?
    @State private var detail: QuestionDetailRoute?
    @State private var handout: HandoutRoute?

    private var flagged: [RoundAnswer] { RoundReview.flagged(answers) }

    /// Server groups once the answer is in; until then (and on failure) the same questions grouped on the device.
    private var groups: [ReviewDisplayGroup] {
        func local(_ groups: [ReviewGroup]) -> [ReviewDisplayGroup] {
            groups.map { g in
                ReviewDisplayGroup(pointID: g.pointID, title: nil, note: nil,
                                   rows: g.items.map { ReviewRow(qid: $0.answer.qid, chosen: $0.answer.chosen,
                                                                correct: $0.answer.correct, answer: [], line: nil) })
            }
        }
        let tags = bank.learning.pointsOfQuestion
        guard case .loaded(let result) = state, !result.groups.isEmpty else {
            return local(RoundReview.group(flagged, pointsOfQuestion: tags))
        }
        let served = result.groups.map { g in
            ReviewDisplayGroup(pointID: g.pointID, title: g.title.isEmpty ? nil : g.title, note: g.note,
                               rows: g.questions.map { q in
                                   ReviewRow(qid: q.qid, chosen: q.chosen, correct: q.correct,
                                             answer: q.answer, line: q.line.isEmpty ? nil : q.line)
                               })
        }
        // The server explains at most three 考點; the rest stay listed (without AI text) so every flagged question shows.
        let servedIDs = Set(served.map(\.pointID))
        let rest = RoundReview.group(flagged, pointsOfQuestion: tags, covered: servedIDs)
        return served + local(RoundReview.notServed(rest, servedPointIDs: servedIDs))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("檢討這回").headingFont(28).accessibilityAddTraits(.isHeader)
                    Text("這輪答錯或猜的 \(flagged.count) 題")
                        .appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted).monospacedDigit()
                }
                confusionCard
                ForEach(groups) { group in groupCard(group) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: backLabel, action: onClose)
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("roundReview")
        .onAppear { if task == nil, state == .loading { load() } }
        .navigationDestination(item: $detail) { QuestionDetailView(route: $0) }
        .navigationDestination(item: $handout) { HandoutView(route: $0, backLabel: "返回檢討這回") }
    }

    // MARK: Loading

    private func load() {
        state = .loading
        let config = AIExplainer.shared?.config ?? AIConfig.load()
        let client = WeakAnalysisClient(config: config, deviceID: UsageLog.shared.deviceID)
        let body = answers
        task = Task {
            do {
                let result = try await client.review(body)
                InsightsStore.shared.merge(result)
                state = .loaded(result)
            } catch is CancellationError {
                state = .failed(.ai(.unreachable))
            } catch let error as WeakAnalysisError {
                state = .failed(error)
            } catch {
                state = .failed(.ai(.unreachable))
            }
            task = nil
        }
    }

    // MARK: AI card

    private func pointTitle(_ g: ReviewDisplayGroup) -> String {
        g.title ?? bank.learning.pointByID[g.pointID]?.title ?? "其他題目"
    }

    @ViewBuilder
    private var confusionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("你可能搞混的地方").appFont(16, .bold).accessibilityAddTraits(.isHeader)
                Chip(text: "AI 產生，請對照課本", kind: .notice).fixedSize()
                Spacer(minLength: 0)
            }
            switch state {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 正在看你選了哪些選項…").appFont(14, relativeTo: .subheadline)
                        Text("通常要 10–30 秒，下面的題目可以先看").appFont(12, relativeTo: .caption1)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 10) {
                    Label(error.message, systemImage: error == .offline ? "wifi.slash" : "exclamationmark.circle")
                        .appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    if error.retryable {
                        Button {
                            Haptics.selection()
                            load()
                        } label: {
                            Label("再試一次", systemImage: "arrow.clockwise")
                                .appFont(14, .bold, relativeTo: .subheadline)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .foregroundStyle(Palette.accent)
                                .background(Capsule().strokeBorder(Palette.accent, lineWidth: 1.5))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .loaded:
                let noted = groups.filter { $0.note?.misconception.isEmpty == false }
                if noted.isEmpty {
                    Text("這輪沒有看出固定的搞混模式，可以直接看下面的題目。")
                        .appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                } else {
                    ForEach(noted) { g in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pointTitle(g)).appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.muted)
                            Text(InlineMarkdown.attributed(g.note?.misconception ?? ""))
                                .appFont(15).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    // MARK: Groups

    private func groupCard(_ group: ReviewDisplayGroup) -> some View {
        let point = bank.learning.pointByID[group.pointID]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pointTitle(group)).appFont(16, .bold).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text("\(group.rows.count) 題").appFont(13, .bold, relativeTo: .footnote).monospacedDigit()
                    .foregroundStyle(Palette.warn)
            }
            .padding(.top, 14).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                questionRow(row, in: group, divider: i > 0)
            }
            if let note = group.note, !note.misconception.isEmpty {
                HStack {
                    Spacer()
                    GroupSaveButton(pointID: group.pointID, note: note, questionIDs: group.rows.map(\.qid))
                }
                .padding(.top, 4)
            }
            if let point {
                Button("讀講義") {
                    Haptics.selection()
                    handout = HandoutRoute(unitID: point.unitID, pointID: point.id)
                }
                .buttonStyle(SecondaryButtonStyle(height: 48))
                .padding(.top, 8).padding(.bottom, 16)
            } else {
                Color.clear.frame(height: 12)
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    @ViewBuilder
    private func questionRow(_ row: ReviewRow, in group: ReviewDisplayGroup, divider: Bool) -> some View {
        if let q = bank.byID[row.qid] {
            let lines = RowText.lines(question: q, chosen: row.chosen, correct: row.correct, answer: row.answer)
            let spoken = lines.joined(separator: "，")
            Button {
                Haptics.selection()
                detail = QuestionDetailRoute(entry: "roundReview", id: q.id, ids: group.rows.map(\.qid), backLabel: "返回檢討這回")
            } label: {
                VStack(spacing: 0) {
                    if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.sourceLabel).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                            Text(lines[0]).appFont(15, .bold).multilineTextAlignment(.leading)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if lines.count > 1 {
                                Text(lines[1]).appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            if let extra = row.line {
                                Text(extra).appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(q.sourceLabel)，\(spoken)" + (row.line.map { "，\($0)" } ?? ""))
            .accessibilityHint("開啟題目")
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// The two text lines of a 檢討這回 question row. Options were shuffled while answering, so the rows show the
/// option content, not the original-paper letters the server and the stored answers use.
enum RowText {
    static let limit = 28

    /// Option text cut to `limit` characters; the letter alone when the option is an image or missing.
    static func option(_ q: Question, letter: String) -> String {
        let text = (q.options[letter] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty { return "圖片選項" }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// `answer`: the server's accepted letters; empty falls back to the question's.
    static func lines(question q: Question, chosen: String, correct: Bool, answer: [String]) -> [String] {
        let letters = answer.isEmpty ? q.answer : answer
        let right = q.allCredit ? "一律給分" : letters.map { option(q, letter: $0) }.joined(separator: "；")
        if chosen.isEmpty { return ["看解答", "答案：" + right] }
        let mine = "你選：" + option(q, letter: chosen)
        return correct ? [mine + "（答對但猜的）"] : [mine, "答案：" + right]
    }
}

/// 「收藏這份筆記」 of one 檢討這回 group.
private struct GroupSaveButton: View {
    let pointID: String
    let note: InsightNote
    let questionIDs: [String]
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @State private var saved = false

    var body: some View {
        SaveNoteButton(saved: saved) {
            Haptics.selection()
            SavedNotes.save(context: context, bank: bank, pointID: pointID, note: note, source: SavedNotes.review,
                            questionIDs: questionIDs)
            withAnimation(.easeInOut(duration: 0.15)) { saved = true }
        }
        .onAppear { saved = SavedNotes.isSaved(context: context, pointID: pointID, note: note) }
    }
}
