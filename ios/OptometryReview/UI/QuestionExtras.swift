import SwiftUI
import SwiftData

// Bookmark, note and related-question pieces shared by review, practice and exam review.

/// Star toggle for one question. Loads its state from the store on appear.
struct BookmarkButton: View {
    let question: Question
    @Environment(\.modelContext) private var context
    @State private var on = false

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { on.toggle() }
            StudyStore(context: context).setBookmark(on, question: question)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? Palette.warn : Palette.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏這題")
        .accessibilityAddTraits(on ? .isSelected : [])
        .onAppear { on = StudyStore(context: context).note(for: question.id)?.bookmarked ?? false }
        .onChange(of: question.id) { on = StudyStore(context: context).note(for: question.id)?.bookmarked ?? false }
    }
}

/// 「我的筆記」 field. Saves as you type (debounced) and when it disappears.
struct NoteField: View {
    let question: Question
    /// Lets the screen move its bottom panel out of the keyboard's way.
    var onFocusChange: ((Bool) -> Void)?
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var loadedID: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("我的筆記").appFont(14, .bold, relativeTo: .subheadline).foregroundStyle(Palette.muted)
            TextField("寫下自己的記法（選填）", text: $text, axis: .vertical)
                .appFont(15)
                .lineLimit(2...8)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Palette.accent : Palette.border, lineWidth: focused ? 1.5 : 1))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { focused = false }
                    }
                }
                .accessibilityLabel("我的筆記")
        }
        .onAppear(perform: load)
        .onChange(of: question.id) { save(); load() }
        .onChange(of: focused) { _, f in
            if !f { save() }
            onFocusChange?(f)
        }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(600))
            save()
        }
        .onDisappear(perform: save)
    }

    private func load() {
        text = StudyStore(context: context).note(for: question.id)?.text ?? ""
        loadedID = question.id
    }

    private func save() {
        guard loadedID == question.id else { return }
        let store = StudyStore(context: context)
        if (store.note(for: question.id)?.text ?? "") != text { store.setNote(text, question: question) }
    }
}

/// 「相關考古題」: up to three same-subject questions with similar wording. Computed lazily, cached per subject.
struct RelatedQuestionsList: View {
    let question: Question
    /// One-line rows for the answer sheet; two-line cards elsewhere.
    var compact = false
    let onOpen: (Question) -> Void

    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @State private var items: [Question] = []
    @State private var loadedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if !items.isEmpty || loadedID != question.id {
                Text("相關考古題").appFont(compact ? 13 : 14, .bold, relativeTo: .subheadline).foregroundStyle(Palette.muted)
            }
            ForEach(items) { item in
                Button { onOpen(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("開啟這題練習")
            }
        }
        .onAppear(perform: load)
        .onChange(of: question.id) { load() }
    }

    private func load() {
        guard loadedID != question.id else { return }
        items = RelatedCache.shared.related(to: question, bank: bank, includeSpecial: includeSpecial)
        loadedID = question.id
    }

    @ViewBuilder
    private func row(_ item: Question) -> some View {
        let source = "\(item.paperLabel) 第 \(item.number) 題"
        if compact {
            HStack(spacing: 8) {
                Text(source).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted).fixedSize()
                Text(item.stem).appFont(14, relativeTo: .subheadline).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("練習").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(item.subject) ・ \(source)").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    Text(item.stem).appFont(15).lineLimit(2).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("練習").appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .contentShape(Rectangle())
        }
    }
}

/// Notes and related questions under an answered question ("question detail").
struct QuestionDetailExtras: View {
    let question: Question
    var showRelated = true
    var onNoteFocus: ((Bool) -> Void)?
    let onOpenRelated: (Question) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NoteField(question: question, onFocusChange: onNoteFocus)
            if showRelated {
                RelatedQuestionsList(question: question, onOpen: onOpenRelated)
            }
        }
    }
}

/// Answer-row presentation for a question shown in `order`. Letters passed in and out are ORIGINAL letters.
struct AnswerPresentation {
    let question: Question
    let order: OptionOrder
    /// Original letter the user chose; nil before answering.
    let chosen: String?

    /// Letters shown as accepted. For all-credit questions only the chosen and original letters are marked.
    var accepted: Set<String> {
        if question.allCredit { return Set([chosen, question.originalAnswer].compactMap { $0 }) }
        return Set(question.answer)
    }

    func state(_ original: String) -> OptionRow.State {
        guard let chosen else { return .idle }
        if accepted.contains(original) { return .correct }
        if original == chosen { return .mine }
        return .idle
    }

    func tag(_ original: String) -> String {
        guard let chosen else { return "" }
        let ok = accepted.contains(original)
        if question.corrected || question.allCredit {
            if ok {
                var lines: [String] = []
                if original == chosen { lines.append("你的答案") }
                if original == question.originalAnswer { lines.append("原答案") }
                lines.append("給分")
                return lines.joined(separator: "\n")
            }
            return original == chosen ? "你的答案" : ""
        }
        if ok { return original == chosen ? "正確答案\n你的答案" : "正確答案" }
        return original == chosen ? "你的答案" : ""
    }

    /// "考選部更正：答C或A者均給分（原公布答案 A）。本 App 以更正答案計分。" with shown letters.
    var correctionText: String? {
        guard let summary = question.correctionSummary else { return nil }
        let original = question.originalAnswer.map { "（原公布答案 \(order.displayedLetter(forOriginal: $0))）" } ?? ""
        return "考選部更正：\(order.mapLetters(in: summary))\(original)。本 App 以更正答案計分。"
    }
}

/// The four option rows in shown order. Taps report the ORIGINAL letter.
struct OrderedOptions: View {
    let question: Question
    let order: OptionOrder
    let state: (String) -> OptionRow.State
    let tag: (String) -> String
    var spacing: CGFloat = 10
    let onTap: (String) -> Void

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(order.shown.enumerated()), id: \.element) { i, original in
                OptionRow(letter: Question.letters[i], text: question.options[original] ?? "",
                          state: state(original), tag: tag(original), lettersOnly: question.optionsAsImage) {
                    onTap(original)
                }
            }
        }
    }
}
