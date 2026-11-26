import SwiftUI

/// The 8 pages of the 0.3.0 tour: five tabs, 怎麼複習, AI 內容, 同步 (design Ob03Tour*).
enum TourPage: Int, CaseIterable {
    case today, units, mistakes, mock, stats, review, ai, sync

    static let count = allCases.count

    var kicker: String {
        switch self {
        case .today, .units, .mistakes, .mock, .stats: "五個分頁"
        case .review: "怎麼複習"
        case .ai: "AI 內容"
        case .sync: "同步"
        }
    }

    var title: String {
        switch self {
        case .today: "今日：每天從這裡開始"
        case .units: "單元：照大綱讀、照單元練"
        case .mistakes: "錯題本：答錯的題都在這"
        case .mock: "模擬考：計時，照國考算分"
        case .stats: "成績：看會不會及格"
        case .review: "錯題會照遺忘的節奏回來"
        case .ai: "官方題和 AI 內容分開標示"
        case .sync: "iPhone、iPad 自動同步"
        }
    }

    var text: String {
        switch self {
        case .today:
            "大卡片是今天的目標，答對設定的題數就達標。按卡片下方的大按鈕先出到期的錯題，不夠再補新題。「五科進度」可以按「練這科」只練一科；「最該補的考點」列出你最近最常錯的地方。"
        case .units:
            "五科依考選部命題大綱分成單元。每個單元有重點講義：考點整理、易錯陷阱、自我小測，做過題後還有依你作答寫的「你的筆記」。讀完可以直接練這個單元的歷屆題；計算題考點另有 AI 題。"
        case .mistakes:
            "答錯的歷屆題自動收進來，可以依科目、年份、單元、錯因篩選，按「練這 N 題」集中練。上方切到「AI 錯題」看答錯的 AI 題；收藏的題目和筆記也在錯題本裡。"
        case .mock:
            "單科模擬每份 50 題、60 分鐘，可選整份歷屆、隨機混合或錯題加強；五科連考照正式考試連考五科。106～115 年的原始試卷也在這裡，可以看原卷或整份練。"
        case .stats:
            "交過的模擬考畫成走勢，照國考及格規則推估「推估及格／未達」。往下看單科分析、考點掌握度和學習紀錄（本週練了幾天）；讀書夥伴也在這裡，和朋友互看本週進度，不排名次。"
        case .review:
            "答錯或按「看解答」的題，今天隔 3 題再出一次，答對才算完成；之後每次到期都答對，間隔就拉長，連續答對、間隔到 3 週以上就算熟練。"
        case .ai:
            "題目和答案以考選部公布的為準，有更正答案時以更正為準。AI 幫你整理講義、出計算題、分析弱點，但可能出錯；和課本不同時，以課本和官方答案為準。"
        case .sync:
            "兩台登入同一個 Apple 帳號並開著 iCloud，作答、錯題排程、筆記和收藏會自動同步，考試日期和每日題數也一起改。iPad 橫放時，講義和 AI 題會分成左右欄，歷屆題的 AI 解析也在右欄。"
        }
    }

    /// 「什麼時候用」 line of the five tab pages.
    var when: String? {
        switch self {
        case .today: "每天打開先來這裡。想換科目範圍或題數，按卡片右上「調整」。"
        case .units: "讀新範圍時先來讀講義；今日點出某個考點弱，也從這裡補。"
        case .mistakes: "考前集中練弱點，或想回頭找某一題時。"
        case .mock: "讀完一科、想知道實力時；想看某年的原卷也來這裡。"
        case .stats: "交完模擬考後；想知道哪一科、哪個考點在拖分時。"
        default: nil
        }
    }

    /// Small print under the text.
    var footnote: String? {
        switch self {
        case .review: "完整規則之後在「設定 › 複習怎麼排」看。"
        case .sync: "導覽和每個功能的說明，之後都在「設定 › 使用說明」。"
        default: nil
        }
    }
}

/// Full-screen tour. First run (new user, or 「先看導覽」 on a second device): 略過 and the last button both finish the
/// first run through `onFinish`. Replay from 使用說明: 關閉 / 完成 just dismisses and writes nothing.
struct TourView: View {
    enum Mode { case firstRun, replay }

    let mode: Mode
    /// First run only: sets the flags (and builds the main screens behind this cover).
    var onFinish: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var forward = true
    @State private var starting = false
    @State private var fading = false

    private var current: TourPage { TourPage(rawValue: page) ?? .today }
    private var isLast: Bool { page == TourPage.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("導覽 \(page + 1)／\(TourPage.count) ・ \(current.kicker)")
                    .appFont(13, .medium, relativeTo: .footnote)
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(mode == .firstRun ? "略過" : "關閉", action: finish)
                    .appFont(16, .medium)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(starting)
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.top, 4)
            ZStack {
                TourPageView(page: current)
                    .id(page)
                    .trackScreen("onboardingTour", page: page + 1)
                    .transition(Motion.questionTransition(reduce: reduceMotion, forward: forward))
            }
            .frame(maxHeight: .infinity)
            .clipped()
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                if v.translation.width < -40 { go(page + 1) } else if v.translation.width > 40 { go(page - 1) }
            })
            VStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(0..<TourPage.count, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Palette.accent : Palette.chipBorder)
                            .frame(width: i == page ? 22 : 8, height: 8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("第 \(page + 1) 頁，共 \(TourPage.count) 頁")
                Button(action: next) {
                    if starting {
                        HStack(spacing: 10) {
                            ProgressView().tint(Palette.onAccent)
                            Text("準備題庫…")
                        }
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .allowsHitTesting(!starting)
            }
            .padding(.horizontal, 24)
            .readableBarWidth()
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .opacity(fading ? 0 : 1)
        .tint(Palette.accent)
    }

    private var buttonTitle: String {
        guard isLast else { return "下一步" }
        return mode == .firstRun ? "開始使用" : "完成"
    }

    private func next() {
        if isLast { finish() } else { go(page + 1) }
    }

    private func go(_ target: Int) {
        guard target >= 0, target < TourPage.count, target != page else { return }
        forward = target > page
        DispatchQueue.main.async {
            withAnimation(Motion.questionAnimation(reduce: reduceMotion)) { page = target }
        }
    }

    private func finish() {
        guard !starting else { return }
        switch mode {
        case .replay:
            dismiss()
        case .firstRun:
            starting = true
            // Building the main tabs runs on the main thread; let the progress state reach the screen first.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                onFinish?()
                withAnimation(.easeInOut(duration: 0.3)) { fading = true }
                try? await Task.sleep(for: .milliseconds(320))
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { dismiss() }
            }
        }
    }
}

/// One tour page: illustration card, title, text, 「什麼時候用」.
private struct TourPageView: View {
    let page: TourPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                illustration
                    .dynamicTypeSize(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.title).headingFont(26).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.text).appFont(15).lineSpacing(5).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let when = page.when {
                        (Text("什麼時候用　").bold().foregroundStyle(Palette.accent) + Text(when))
                            .appFont(14, relativeTo: .subheadline).lineSpacing(4)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentSoft))
                    }
                    if let footnote = page.footnote {
                        Text(footnote).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readableScrollWidth()
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var illustration: some View {
        switch page {
        case .today: TourCard(selected: 0) { todayMock }
        case .units: TourCard(selected: 1) { unitsMock }
        case .mistakes: TourCard(selected: 2) { mistakesMock }
        case .mock: TourCard(selected: 3) { mockMock }
        case .stats: TourCard(selected: 4) { statsMock }
        case .review: TourCard(tag: false) { reviewMock }
        case .ai: TourCard(tag: false, height: 318) { aiMock }
        case .sync: TourCard { syncMock }
        }
    }

    // MARK: Mock content (all 示意)

    private var todayMock: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("今天答對").appFont(12).opacity(0.85)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("0").appFont(30, .bold).monospacedDigit()
                    Text("/ 20").appFont(14).opacity(0.85)
                }
                Capsule().fill(Palette.onAccent.opacity(0.25)).frame(height: 5)
                Text("新題 14 ・ 待複習 6 ・ 再次挑戰 0").appFont(11).monospacedDigit().opacity(0.9)
                Text("開始今天的 20 題").appFont(14, .bold).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.onAccent))
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text("最該補的考點").appFont(12, .bold)
                HStack {
                    Text("Prentice 法則與基底方向").appFont(13)
                    Spacer(minLength: 4)
                    mockChip("待加強", fg: Palette.warn, bg: Palette.warnSoft)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
        }
    }

    private var unitsMock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("視覺光學").appFont(12).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Text("鏡片稜鏡與偏心").appFont(14, .bold).frame(maxWidth: .infinity, alignment: .leading)
                mockCount("歷屆", "72", color: Palette.ink)
                mockCount("AI 題", "120", color: Palette.noticeInk)
                mockCount("錯題", "7", color: Palette.warn, bold: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("重點講義").appFont(13, .bold)
                    Spacer()
                    Text("AI 產生，請對照課本").appFont(10, .bold, relativeTo: .caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(Palette.noticeInk)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.notice))
                }
                Divider()
                HStack {
                    Text("考點 1　Prentice 法則與基底方向").appFont(13)
                    Spacer(minLength: 4)
                    mockChip("待加強", fg: Palette.warn, bg: Palette.warnSoft)
                }
                HStack {
                    Text("考點 2　稜鏡的合成與分解").appFont(13)
                    Spacer(minLength: 4)
                    mockChip("穩定", fg: Palette.accent, bg: Palette.accentSoft)
                }
                Text("自我小測　5 題").appFont(13).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    private var mistakesMock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                Text("歷屆 31").appFont(12, .bold).frame(maxWidth: .infinity, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
                Text("AI 錯題 4").appFont(12).frame(maxWidth: .infinity, minHeight: 30)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.segmentTrack))
            .padding(.trailing, 44)
            HStack(spacing: 6) {
                Text("篩選・2").appFont(12, .bold).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(Capsule().strokeBorder(Palette.accent, lineWidth: 1.5))
                mockChip("視覺光學 ✕", fg: Palette.ink, bg: Palette.accentSoft)
                mockChip("算錯 ✕", fg: Palette.warn, bg: Palette.warnSoft)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("113 年第二次 ・ 視覺光學").appFont(11).foregroundStyle(Palette.muted)
                    Spacer()
                    Text("今天複習").appFont(11, .bold).foregroundStyle(Palette.warn)
                }
                Capsule().fill(Palette.border).frame(height: 6)
                Capsule().fill(Palette.border).frame(height: 6).padding(.trailing, 90)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            Text("練這 12 題").appFont(13, .bold).foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent))
        }
    }

    private var mockMock: some View {
        VStack(spacing: 10) {
            mockRow("五科連考模擬", "五科連考，考完才公布分數")
            mockRow("單科模擬", "整份歷屆、隨機混合或錯題加強")
            VStack(alignment: .leading, spacing: 4) {
                Text("歷屆試卷").appFont(13, .bold)
                Text("考選部原始試卷，看整份或逐題練").appFont(11).foregroundStyle(Palette.muted)
                HStack(spacing: 6) {
                    ForEach(["115 年", "114 年", "113 年"], id: \.self) { y in
                        Text(y).appFont(11).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.ground))
                    }
                    Text("⋯ 106 年").appFont(11).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent, lineWidth: 2))
        }
    }

    private var statsMock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("五科平均 58 分").appFont(15, .bold).monospacedDigit()
                Spacer()
                mockChip("推估未達", fg: Palette.warn, bg: Palette.warnSoft)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            VStack(alignment: .leading, spacing: 8) {
                Text("考點掌握度").appFont(12, .bold)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        Rectangle().fill(Palette.warn).frame(width: g.size.width * 0.22)
                        Rectangle().fill(Palette.shaky).frame(width: g.size.width * 0.28)
                        Rectangle().fill(Palette.accent).frame(width: g.size.width * 0.36)
                        Rectangle().fill(Palette.chipBorder)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 10) {
                    legend("待加強", Palette.warn)
                    legend("還不穩", Palette.shaky)
                    legend("穩定", Palette.accent)
                    legend("沒做過", Palette.chipBorder)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
        }
    }

    private var reviewMock: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReviewIntervalDiagram()
            VStack(alignment: .leading, spacing: 10) {
                bulletRow("hand.thumbsup", "第一次答對但沒把握，勾「猜的」：當錯題排進複習；沒勾的約 8 天後再出一次確認。")
                bulletRow("calendar", "設了考試日期：最晚在考前 3 天複習；考前 2 週起，還沒熟練的錯題每天出。")
                bulletRow("timer", "模擬考答錯的題也會排進複習。")
            }
        }
    }

    private var aiMock: some View {
        VStack(alignment: .leading, spacing: 10) {
            aiRow(Text("歷屆").appFont(10, .bold).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.accentSoft)),
                  "考選部公布的原題與答案。算進正確率、錯題本、每日複習、模擬考和及格推估。")
            aiRow(noticeLabel("AI 出題，非官方・AI 自動檢核"),
                  "AI 照歷屆計算題的算法換數字出的題。只算一半進考點掌握度，其餘都不算。")
            aiRow(noticeLabel("AI 產生，請對照課本"), "整塊 AI 寫的內容：重點講義、AI 解析、你的筆記、檢討這回。")
            aiRow(noticeLabel("AI 分析"), "夾在一般內容裡的一行 AI 說明，例如「最該補的考點」旁的理由。")
            VStack(alignment: .leading, spacing: 4) {
                Text("圖解 ・ 依題目參數繪製、已驗算").appFont(11).foregroundStyle(Palette.muted)
                Text("AI 題的圖由程式照題目數字畫；畫錯了按「圖有誤」。").appFont(12).lineSpacing(3)
            }
        }
    }

    private var syncMock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("設定 › 資料").appFont(12).foregroundStyle(Palette.muted)
            HStack {
                Text("iCloud 同步").appFont(14)
                Spacer()
                Text("已同步").appFont(14).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
            Text("兩台都已有作答時，第二台第一次打開會問一次").appFont(12).foregroundStyle(Palette.muted)
            VStack(spacing: 8) {
                HStack {
                    Text("改用 iCloud 上的紀錄").appFont(13, .bold)
                    Spacer()
                    Text("建議").appFont(10, .bold, relativeTo: .caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(Palette.onAccent)
                        .background(Capsule().fill(Palette.accent))
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent, lineWidth: 1.5))
                HStack {
                    Text("合併兩邊").appFont(13, .bold)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border, lineWidth: 1))
            }
        }
    }

    // MARK: Pieces

    private func mockChip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).appFont(11, .bold, relativeTo: .caption2)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .fixedSize()
    }

    private func mockCount(_ label: String, _ value: String, color: Color, bold: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(label).appFont(10, relativeTo: .caption2).foregroundStyle(color == Palette.ink ? Palette.muted : color)
            Text(value).appFont(13, bold ? .bold : .regular).monospacedDigit().foregroundStyle(color)
        }
    }

    private func mockRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(13, .bold)
            Text(detail).appFont(11).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).appFont(11, relativeTo: .caption2).foregroundStyle(Palette.muted)
        }
    }

    private func bulletRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 24, height: 24)
            Text(text).appFont(13).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noticeLabel(_ text: String) -> some View {
        Text(text).appFont(10, .bold, relativeTo: .caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(Palette.noticeInk)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.notice))
    }

    private func aiRow<L: View>(_ label: L, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            Text(text).appFont(12).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }
}

/// White illustration card with the 「示意」 tag; with `selected` it ends in the mini tab bar.
private struct TourCard<Content: View>: View {
    var selected: Int?
    var tag = true
    var height: CGFloat = 300
    @ViewBuilder let content: Content

    init(selected: Int? = nil, tag: Bool = true, height: CGFloat = 300, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.tag = tag
        self.height = height
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, selected == nil ? 16 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let selected {
                MiniTabBar(selected: selected)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 24).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            if tag {
                Text("示意").appFont(10, .medium, relativeTo: .caption2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(Palette.muted)
                    .background(Capsule().fill(Palette.hairline))
                    .padding(.top, 12).padding(.trailing, 14)
            }
        }
    }
}

/// The five tabs in miniature with one highlighted (same icons as the real tab bar).
private struct MiniTabBar: View {
    let selected: Int
    private static let items: [(String, String)] = [("今日", "calendar"), ("單元", "books.vertical"),
                                                     ("錯題本", "book.closed"), ("模擬考", "timer"), ("成績", "chart.bar")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 2) {
                    Image(systemName: item.1).font(.system(size: 15))
                    Text(item.0).appFont(10, i == selected ? .bold : .regular, relativeTo: .caption2)
                }
                .foregroundStyle(i == selected ? Palette.accent : Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(i == selected ? Palette.accentSoft : Color.clear))
                .padding(2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
