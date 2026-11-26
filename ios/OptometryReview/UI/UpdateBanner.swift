import SwiftUI

/// Banner at the top of 今日: a newer build exists (dismissible) or this build is below the minimum (not dismissible).
struct UpdateBanner: View {
    let notice: UpdateNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var required: Bool { notice.kind == .required }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: required ? "exclamationmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                    Text(notice.text)
                        .appFont(15, required ? .bold : .semibold, relativeTo: .subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if required {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, required ? 14 : 4)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("開啟 TestFlight")
            if !required {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉更新提示")
            }
        }
        .foregroundStyle(required ? Palette.onWarn : Palette.ink)
        .background(RoundedRectangle(cornerRadius: 14).fill(required ? Palette.warn : Palette.accentSoft))
        .accessibilityElement(children: .contain)
    }
}
