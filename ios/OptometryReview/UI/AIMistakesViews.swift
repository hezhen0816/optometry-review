import SwiftUI
import SwiftData

/// Request to practice (or just re-read) AI questions; presented full screen.
struct AIPracticeRequest: Identifiable, Hashable {
    let id = UUID()
    let ids: [String]
    /// Opens `reviewID` in its answered state without recording anything.
    var reviewID: String? = nil
    var reviewChosen = ""
}

extension AIPracticeView {
    init(request: AIPracticeRequest) {
        self.init(ids: request.ids, reviewing: request.reviewID.map { ($0, request.reviewChosen) })
    }
}

extension QuestionDetailRoute: Identifiable {}

/// 錯題本 top segment: 歷屆 ｜ AI 錯題.
enum MistakesMode: String, CaseIterable {
    case official, ai
}

/// 收藏 segments: 歷屆 ｜ AI 題 ｜ AI 筆記.
enum SavedSegment: String, CaseIterable {
    case official, aiQuestions, aiNotes
    var title: String {
        switch self {
        case .official: "歷屆"
        case .aiQuestions: "AI 題"
        case .aiNotes: "AI 筆記"
        }
    }
}

private func relativeDay(_ date: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day ?? 0
    switch days {
    case 0: return "今天答錯"
    case 1: return "昨天答錯"
    default: return "\(DateText.monthDay.string(from: date)) 答錯"
    }
}

// MARK: - AI 錯題

/// AI 錯題: questions whose latest AI answer is wrong. One correct answer removes the question.
struct AIMistakesList: View {
    let mistakes: [AIMistake]
    let onOpen: (AIMistake) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                AIBadge()
                Text("再答對一次就移出")
                    .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            if mistakes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text("目前沒有 AI 錯題").appFont(15, .bold)
                    Text("到「單元」練 AI 題，答錯的會收進來。").appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(mistakes) { m in
                        Button { onOpen(m) } label: { row(m) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func row(_ m: AIMistake) -> some View {
        let q = m.question
        let point = q.pointIDs.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PointTitle(pointID: point, fallback: q.subject)
                Spacer(minLength: 6)
                Text(relativeDay(m.at)).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            Text(q.stem).appFont(15).lineSpacing(5).lineLimit(3).multilineTextAlignment(.leading)
            Text((m.chosen.isEmpty ? "看了解答" : "你選 \(q.options[m.chosen] ?? m.chosen)") + " ・ 答案 \(q.answerText)")
                .appFont(13, .bold, relativeTo: .footnote).foregroundStyle(Palette.warn).monospacedDigit()
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看解題步驟")
    }
}

private struct PointTitle: View {
    let pointID: String?
    let fallback: String
    @Environment(\.questionBank) private var bank

    var body: some View {
        Text(pointID.flatMap { bank.learning.pointByID[$0]?.title } ?? fallback)
            .appFont(12, .medium, relativeTo: .caption1)
            .lineLimit(1)
    }
}

// MARK: - 收藏 ・ AI 題

/// Bookmarked AI questions (the ☆ on the AI answer screen).
struct AISavedQuestionsList: View {
    let onOpen: (AIQuestion) -> Void
    @Environment(\.questionBank) private var bank
    @Query(filter: #Predicate<QuestionNote> { $0.bookmarked }, sort: \QuestionNote.updatedAt, order: .reverse)
    private var notes: [QuestionNote]

    private var questions: [AIQuestion] {
        notes.compactMap { AIQID.isAI($0.questionID) ? bank.ai.byID[$0.questionID] : nil }
    }

    var body: some View {
        let list = questions
        VStack(alignment: .leading, spacing: 12) {
            AIBadge().padding(.horizontal, 20)
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text("答 AI 題時點右上角星號收藏").appFont(15).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(list) { q in
                        Button { onOpen(q) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PointTitle(pointID: q.pointIDs.first, fallback: q.subject)
                                Text(q.stem).appFont(15).lineSpacing(5).lineLimit(3).multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - 收藏 ・ AI 筆記

struct SavedNoteRoute: Hashable {
    let noteID: UUID
}

/// Saved AI notes, newest first.
struct AISavedNotesList: View {
    let onOpen: (SavedNote) -> Void
    @Query(sort: \SavedNote.savedAt, order: .reverse) private var notes: [SavedNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chip(text: "AI 產生，請對照課本", kind: .notice).fixedSize().padding(.horizontal, 20)
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text("在「你的筆記」或「檢討這回」點「收藏這份筆記」").appFont(15).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50).padding(.horizontal, 20)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(notes) { n in
                        Button { onOpen(n) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text([n.subject, n.title].filter { !$0.isEmpty }.joined(separator: " ・ "))
                                        .appFont(12, .medium, relativeTo: .caption1).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(DateText.monthDay.string(from: n.savedAt))
                                        .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                                }
                                Text(InlineMarkdown.attributed(n.misconception.isEmpty ? n.fix : n.misconception))
                                    .appFont(15).lineSpacing(5).lineLimit(3).multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// Read-only saved note: same look as 你的筆記, with the saved date and a delete button.
struct SavedNoteView: View {
    let noteID: UUID
    let backLabel: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Query private var notes: [SavedNote]
    @State private var confirmDelete = false
    @State private var handout: HandoutRoute?

    private var note: SavedNote? { notes.first { $0.noteID == noteID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let n = note {
                    VStack(alignment: .leading, spacing: 4) {
                        Text([n.subject, bank.unitByID[n.unitID]?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ・ "))
                            .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        Text(n.title.isEmpty ? "AI 筆記" : n.title).headingFont(25)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HandoutNoteCard(note: SavedNotes.insight(n), answerCount: nil, savedOn: n.savedAt)
                    if bank.learning.pointByID[n.pointID] != nil {
                        Button("讀講義") {
                            Haptics.selection()
                            handout = HandoutRoute(unitID: n.unitID, pointID: n.pointID)
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 48))
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("刪除這份筆記").appFont(15, .medium).foregroundStyle(Palette.warn)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("這份筆記已刪除").appFont(15).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 32)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: backLabel) { dismiss() }
                Spacer()
            }
            .padding(.leading, 10).padding(.vertical, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("savedNote")
        .navigationDestination(item: $handout) { HandoutView(route: $0, backLabel: "返回筆記") }
        .confirmationDialog("刪除這份筆記？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                if let n = note { context.delete(n); try? context.save() }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只刪除你收藏的這份副本，AI 之後產生的新筆記不受影響。")
        }
    }
}
