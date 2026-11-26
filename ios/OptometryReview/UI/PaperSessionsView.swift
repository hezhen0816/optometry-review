import SwiftUI

/// 歷屆試卷 section of the 模擬考 tab: 一般考試／特考 by year, each year expandable to its subject papers.
struct PaperSessionsView: View {
    let onOpen: (Paper) -> Void

    @Environment(\.questionBank) private var bank
    @State private var kind = PaperSessionsView.kinds[0]
    @State private var openCode: String?

    static let kinds = ["一般考試", "特考（已執業者）"]

    private var sessions: [ExamSession] {
        PaperCatalog.sessions(bank.papers, kind: kind == Self.kinds[0] ? ExamKind.general : ExamKind.special)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("歷屆試卷").appFont(15, .bold).foregroundStyle(Palette.muted)
                Text("考選部原始試卷，看整份或逐題練")
                    .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            .coachTarget()
            SegmentPicker(options: Self.kinds, selection: $kind)
            LazyVStack(spacing: 8) {
                ForEach(sessions) { session in sessionCard(session) }
            }
            if kind != Self.kinds[0] {
                Text("特考是給已執業者的考試。每日複習與隨機模擬預設不出特考題，可在設定開啟。")
                    .appFont(12, relativeTo: .caption1)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { if openCode == nil { openCode = sessions.first?.code } }
        .onChange(of: kind) { openCode = sessions.first?.code }
    }

    private func sessionCard(_ session: ExamSession) -> some View {
        let open = openCode == session.code
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { openCode = open ? nil : session.code }
            } label: {
                HStack(spacing: 10) {
                    Text(session.label).appFont(15, .bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !open {
                        Text("\(session.papers.count) 科").appFont(12, relativeTo: .caption1)
                            .foregroundStyle(Palette.muted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? "已展開" : "已收合")
            if open {
                VStack(spacing: 0) {
                    ForEach(session.papers) { paper in
                        Button { onOpen(paper) } label: { paperRow(paper) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func paperRow(_ paper: Paper) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Text(paper.subject).appFont(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if bank.hasCorrection(paper) { TagBadge(text: "有更正", notice: true) }
                if paper.calculatorAllowed { TagBadge(text: "可用計算器") }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }
}
