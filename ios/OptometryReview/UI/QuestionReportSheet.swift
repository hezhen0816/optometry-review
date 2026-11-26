import SwiftUI

/// 「題目有誤」 sheet: one category plus an optional note, sent through the usage event queue.
struct QuestionReportSheet: View {
    let question: Question
    /// Called after the report is queued (the screen shows 「已回報，謝謝」).
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @State private var category: QuestionReport.Category?
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScopeSheet(title: "題目有誤", subtitle: "\(question.sourceLabel)・\(question.subject)", onClose: { dismiss() }) {
            ScopeField(title: "哪裡有誤") {
                VStack(spacing: 8) {
                    ForEach(QuestionReport.Category.allCases) { c in categoryRow(c) }
                }
            }
            ScopeField(title: "補充說明（選填）") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("例如：第二個選項少了一個字", text: $note, axis: .vertical)
                        .appFont(15)
                        .lineLimit(2...6)
                        .focused($noteFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(noteFocused ? Palette.accent : Palette.border, lineWidth: noteFocused ? 1.5 : 1))
                        .onChange(of: note) { _, v in
                            if v.count > QuestionReport.maxNoteLength { note = String(v.prefix(QuestionReport.maxNoteLength)) }
                        }
                        .accessibilityLabel("補充說明")
                    if note.count > QuestionReport.maxNoteLength - 50 {
                        Text("\(note.count) / \(QuestionReport.maxNoteLength)")
                            .appFont(11, relativeTo: .caption2)
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        } footer: {
            if !usageEnabled {
                Text("回報經「使用紀錄回傳」送出，請先到設定開啟。")
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if QuestionReport.isReported(question.id) {
                Text("這題回報過，可以再回報另一個問題。")
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geo in
                HStack(spacing: 10) {
                    Button("取消") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle(height: 52, inverted: true))
                        .frame(width: (geo.size.width - 10) / 3)
                    Button("送出") { send() }
                        .buttonStyle(PrimaryButtonStyle(height: 52))
                        .disabled(category == nil || !usageEnabled)
                }
            }
            .frame(height: 52)
        }
        .trackScreen("questionReport")
    }

    private func categoryRow(_ c: QuestionReport.Category) -> some View {
        let on = category == c
        return Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { category = c }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Palette.accent : Palette.muted)
                Text(c.title).appFont(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accentSoft : Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func send() {
        guard let category else { return }
        Haptics.selection()
        QuestionReport.submit(question, category: category, note: note)
        dismiss()
        onSent()
    }
}

/// 「題目有誤」 menu entry. A question reported before says so but can still be reported again (another problem).
struct QuestionReportMenuItem: View {
    let question: Question
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(QuestionReport.isReported(question.id) ? "題目有誤（已回報過）" : "題目有誤",
                  systemImage: "exclamationmark.bubble")
        }
    }
}

/// Shows 「已回報，謝謝」 for a moment.
@MainActor
func showReportToast(_ flag: Binding<Bool>) {
    withAnimation(.easeInOut(duration: 0.2)) { flag.wrappedValue = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        withAnimation(.easeInOut(duration: 0.2)) { flag.wrappedValue = false }
    }
}
