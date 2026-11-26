import SwiftUI

/// 今日「五科進度」: per subject how many questions of the 練習範圍 were answered, a bar, and 「練這科」.
struct TodaySubjectProgressCard: View {
    let progress: [SubjectProgress]
    let onPractice: (String) -> Void

    /// Warn colours and the header count only show when practice is lopsided (`SubjectProgress.flagsNeglect`).
    private var flagging: Bool { SubjectProgress.flagsNeglect(progress) }
    private var neglectedCount: Int { flagging ? progress.filter(\.isNeglected).count : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("五科進度").appFont(15, .bold).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if neglectedCount > 0 {
                    Text("\(neglectedCount) 科還很少練").appFont(13, .bold, relativeTo: .footnote)
                        .foregroundStyle(Palette.warn)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
            ForEach(Array(progress.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                row(p)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func row(_ p: SubjectProgress) -> some View {
        let flagged = flagging && p.isNeglected
        let tint = flagged ? Palette.warn : Palette.accent
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(p.subject).appFont(14, .medium, relativeTo: .subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("做過 \(p.answered)／\(p.total) 題")
                        .appFont(12, flagged ? .bold : .regular, relativeTo: .caption1)
                        .monospacedDigit()
                        .foregroundStyle(flagged ? Palette.warn : Palette.muted)
                }
                Capsule().fill(Palette.hairline)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(tint).frame(width: max(p.answered > 0 ? 3 : 0, geo.size.width * p.fraction))
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue("做過 \(p.answered) 題，共 \(p.total) 題" + (flagged ? "，還很少練" : ""))
            Button {
                Haptics.selection()
                onPractice(p.subject)
            } label: {
                if flagging {
                    // Lopsided practice: the weak subjects get a filled button.
                    Text("練這科").appFont(13, .bold, relativeTo: .footnote)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(p.isNeglected ? Palette.warnSoft : Palette.badge))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                } else {
                    // Nothing to flag: a quiet text link, so the five of them do not compete with the main button.
                    Text("練這科 ›").appFont(13, .medium, relativeTo: .footnote)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("練\(p.subject)")
        }
        .frame(minHeight: 52)
    }
}
