import SwiftUI

// Pieces shared by the follow-up thread (AIExplainPanel) and 問講義 (HandoutAskView).

/// The follow-up input: multi-line field with a send button and a length counter near the limit.
struct ChatInputRow: View {
    let placeholder: String
    let sendLabel: String
    @Binding var text: String
    var disabled = false
    var maxLength = AIClient.maxQuestionLength
    var onFocusChange: ((Bool) -> Void)?
    let onSend: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .appFont(15)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(focused ? Palette.accent : Palette.border, lineWidth: focused ? 1.5 : 1))
                    .onChange(of: text) { _, v in
                        if v.count > maxLength { text = String(v.prefix(maxLength)) }
                    }
                    .accessibilityLabel(placeholder.replacingOccurrences(of: "…", with: ""))
                Button {
                    onSend()
                    focused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(trimmed.isEmpty || disabled ? Palette.border : Palette.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || disabled)
                .accessibilityLabel(sendLabel)
            }
            if text.count > maxLength - 50 {
                Text("\(text.count) / \(maxLength)")
                    .appFont(11, relativeTo: .caption2)
                    .foregroundStyle(text.count >= maxLength ? Palette.warn : Palette.muted)
            }
        }
        .onChange(of: focused) { _, f in onFocusChange?(f) }
    }
}

/// One message of a thread. `rich` renders the text as light Markdown (AI answers).
struct ChatBubble: View {
    let text: String
    let mine: Bool
    var rich = false

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Group {
                if rich {
                    ChatMarkdown(text: text)
                } else {
                    Text(text)
                        .appFont(15)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(mine ? Palette.accentSoft : (rich ? Palette.card : Palette.ground)))
            .overlay { if rich && !mine { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border, lineWidth: 1) } }
            if !mine { Spacer(minLength: 24) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mine ? "你問：\(text)" : "AI 回答：\(text)")
    }
}

/// Markdown subset the answers use: headings, bullet and numbered lists, table rows as plain lines, **bold**/`code` inline.
enum ChatMarkdownBlock: Equatable {
    case heading(String)
    case bullet(String)
    case numbered(Int, String)
    case paragraph(String)
    case table(header: [String], rows: [[String]])

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ line: String) -> Bool {
        let c = cells(line)
        return !c.isEmpty && c.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
    }

    static func parse(_ text: String) -> [ChatMarkdownBlock] {
        var out: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if s.isEmpty { flush(); continue }
            if s.allSatisfy({ "-*_ ".contains($0) }) && s.filter({ $0 != " " }).count >= 3 { flush(); continue }
            if s.hasPrefix("#") {
                flush()
                out.append(.heading(String(s.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if s.hasPrefix("|") {
                flush()
                var rows: [[String]] = [cells(s)]
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if isSeparator(row) { continue }
                    rows.append(cells(row))
                }
                out.append(.table(header: rows[0], rows: Array(rows.dropFirst())))
            } else if let m = s.firstMatch(of: /^(\d+)[.)]\s+/) {
                flush()
                out.append(.numbered(Int(m.1) ?? 1, String(s[m.range.upperBound...])))
            } else if let m = s.firstMatch(of: /^[-*•]\s+/) {
                flush()
                out.append(.bullet(String(s[m.range.upperBound...])))
            } else {
                paragraph.append(s)
            }
        }
        flush()
        return out
    }
}

struct ChatMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(InlineMarkdown.attributed(t)).appFont(16, .bold).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let t):
                    row("•", t)
                case .numbered(let n, let t):
                    row("\(n).", t)
                case .paragraph(let t):
                    Text(InlineMarkdown.attributed(t)).appFont(15).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let header, let rows):
                    ChatTable(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ marker: String, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).appFont(15).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(minWidth: 16, alignment: .trailing)
            Text(InlineMarkdown.attributed(t)).appFont(15).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small grid for a Markdown table: equal-width columns, header row tinted, thin borders.
struct ChatTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(header, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(Palette.hairline).frame(height: 1)
                row(r, isHeader: false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(header.indices, id: \.self) { i in
                Text(InlineMarkdown.attributed(cells.indices.contains(i) ? cells[i] : ""))
                    .appFont(14, isHeader ? .bold : .regular, relativeTo: .subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(isHeader ? Palette.accentSoft : Color.clear)
    }
}
