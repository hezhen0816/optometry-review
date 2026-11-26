import SwiftUI

/// 圖解 card of an AI question: the drawing, 「圖解・依參數繪製、已驗算」 and 「圖有誤」.
/// Nothing is drawn when the parameters are unusable or the recomputed values disagree with the steps.
struct AIFigureCard: View {
    let question: AIQuestion
    @State private var showReport = false
    @State private var hiddenNow = false

    private var hidden: Bool { hiddenNow || AIPractice.hiddenFigureIDs().contains(question.id) }

    var body: some View {
        if let figure = AIFigure.checked(question.figure, steps: question.steps, answerText: question.answerText) {
            if hidden {
                Label("這張圖已回報，先隱藏", systemImage: "flag")
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            } else {
                AIFigureFrame(figure: figure) { showReport = true }
                    .sheet(isPresented: $showReport) {
                        AIFigureReportSheet(question: question) {
                            hiddenNow = true
                        }
                        .presentationDetents([.large])
                    }
            }
        }
    }
}

/// The bordered figure with its caption and 「圖有誤」; also used by the debug gallery.
struct AIFigureFrame: View {
    let figure: AIFigure
    var caption = "圖解"
    var onReport: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(caption).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onReport {
                    Button {
                        Haptics.selection()
                        onReport()
                    } label: {
                        Label("圖有誤", systemImage: "flag")
                            .appFont(13, .medium, relativeTo: .footnote)
                            .foregroundStyle(Palette.accent)
                            .padding(.leading, 8).padding(.trailing, 4)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -8)
                    .padding(.trailing, -4)
                    .accessibilityLabel("回報這張圖有誤")
                }
            }
            AIFigureCanvas(figure: figure)
                .frame(maxWidth: .infinity)
            // Numbered explanation: row n belongs to badge n on the drawing.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(figure.legend.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").appFont(11, .bold, relativeTo: .caption2)
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Palette.accent))
                        Text(line).appFont(13, relativeTo: .footnote).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// 「圖有誤」 sheet: one reason plus an optional note; sending also hides the figure on this device.
struct AIFigureReportSheet: View {
    let question: AIQuestion
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @State private var reason: AIReport.FigureReason = .direction
    @State private var note = ""

    var body: some View {
        ScopeSheet(title: "圖有誤",
                   subtitle: "送出後，這張圖在你的手機上先隱藏，只留文字解題步驟。會送出這張圖的種類、參數和你選的原因，不含你的作答。",
                   onClose: { dismiss() }) {
            ScopeField(title: "哪裡有誤") {
                VStack(spacing: 2) {
                    ForEach(AIReport.FigureReason.allCases) { r in row(r) }
                }
            }
            ScopeField(title: "補充（可不填）") {
                TextField("例如：負鏡片應該背離光心", text: $note, axis: .vertical)
                    .appFont(15)
                    .lineLimit(2...5)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 1))
                    .accessibilityLabel("補充說明")
            }
        } footer: {
            if !usageEnabled {
                Text("回報經「使用紀錄回傳」送出，沒開啟時只會在這支手機隱藏這張圖。")
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("送出並隱藏這張圖") {
                Haptics.selection()
                AIReport.submitFigure(question, reason: reason, note: note)
                dismiss()
                onSent()
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))
        }
        .trackScreen("aiFigureReport")
    }

    private func row(_ r: AIReport.FigureReason) -> some View {
        let on = reason == r
        return Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.15)) { reason = r }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20)).foregroundStyle(on ? Palette.accent : Palette.muted)
                Text(r.title).appFont(15, on ? .bold : .regular).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 「題目有誤」 sheet for an AI question: same wording and categories as the official one.
struct AIQuestionReportSheet: View {
    let question: AIQuestion
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @State private var category: QuestionReport.Category?
    @State private var note = ""

    var body: some View {
        ScopeSheet(title: "題目有誤", subtitle: "AI 出題・\(question.subject)", onClose: { dismiss() }) {
            ScopeField(title: "哪裡有誤") {
                VStack(spacing: 8) {
                    ForEach(QuestionReport.Category.allCases) { c in
                        let on = category == c
                        Button {
                            Haptics.selection()
                            category = c
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 20)).foregroundStyle(on ? Palette.accent : Palette.muted)
                                Text(c.title).appFont(16).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accentSoft : Palette.card))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            ScopeField(title: "補充說明（選填）") {
                TextField("例如：第二個選項少了一個字", text: $note, axis: .vertical)
                    .appFont(15).lineLimit(2...6)
                    .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 1))
            }
        } footer: {
            if !usageEnabled {
                Text("回報經「使用紀錄回傳」送出，請先到設定開啟。")
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(height: 52, inverted: true))
                Button("送出") {
                    guard let category else { return }
                    AIReport.submitQuestion(question, category: category, note: note)
                    dismiss()
                    onSent()
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))
                .disabled(category == nil || !usageEnabled)
            }
        }
        .trackScreen("questionReport")
    }
}
