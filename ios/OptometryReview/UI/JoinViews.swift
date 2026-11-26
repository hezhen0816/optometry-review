import SwiftUI

/// First iCloud launch of a device that already has answers: the short check before the app opens (FirstJoin.swift).
struct JoinCheckingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在檢查 iCloud 上的學習紀錄…").appFont(15).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }
}

/// Both iCloud and this device hold answers: she picks, once per device, before sync starts.
struct JoinChoiceView: View {
    let local: Int
    let remote: Int?
    let recommendICloud: Bool
    let choose: (AppStoreLoader.Choice) -> Void
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("開始 iCloud 同步").headingFont(28)
                Text(intro)
                    .appFont(15)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("如果另一台是 iPhone，建議先更新並打開 iPhone，等「設定 › 資料 › iCloud 同步」顯示已同步，再回這台選。")
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                option(title: "改用 iCloud 上的紀錄",
                       detail: "這台的 \(local) 筆會先存成匯出檔，之後可在「設定 › 資料」加回來",
                       recommended: recommendICloud) { pick(.useICloud) }
                option(title: "合併兩邊", detail: "兩台的作答紀錄全部保留",
                       recommended: !recommendICloud) { pick(.merge) }
                if busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("處理中…").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    }
                }
                Text("每台裝置只會問一次。")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .trackScreen("iCloudJoin")
    }

    private var intro: String {
        let theirs = remote.map { "（作答 \($0) 筆）" } ?? ""
        return "iCloud 上已經有另一台裝置的學習紀錄\(theirs)。這台有 \(local) 筆。"
    }

    private func pick(_ choice: AppStoreLoader.Choice) {
        guard !busy else { return }
        busy = true
        Haptics.selection()
        // Let the progress row draw before the store work runs on the main actor.
        DispatchQueue.main.async { choose(choice) }
    }

    private func option(title: String, detail: String, recommended: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).appFont(16, .semibold).foregroundStyle(Palette.accent)
                        if recommended { TagBadge(text: "建議", notice: true) }
                    }
                    Text(detail)
                        .appFont(13, relativeTo: .footnote)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(16)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(recommended ? Palette.accent : Palette.hairline, lineWidth: recommended ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
