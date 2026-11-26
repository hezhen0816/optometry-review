import SwiftUI

// How reviews are scheduled, in the learner's words. Facts follow Scheduler / ExamDatePolicy / DailyPlanner:
// a wrong answer (or 看解答) returns three questions later in 今日練習 and is due tomorrow; plain correct answers at
// each due review stretch the FSRS interval (about 1, 2, 6, 17 days with the default parameters); mastered = at
// least two due correct answers in a row and a next interval of 21 days or more; with an exam date, long intervals
// are capped at exam − 3 days and open mistakes are due daily from exam − 14 days. A first plain-correct answer is a
// 確認題 (FSRS Easy, about 8 days, not a mistake); due 確認題 fill at most a third of the daily goal until one month
// before the exam (DailyPlanner.confirmationLimit).

/// 「答錯之後每次都答對」: 再練一次 → 明天 → 2 天 → 6 天 → 17 天 → 熟練.
struct ReviewIntervalDiagram: View {
    private static let steps = ["明天", "2 天", "6 天", "17 天"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("答錯").appFont(12, .bold, relativeTo: .caption1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(Palette.warn)
                    .background(Capsule().fill(Palette.warnSoft))
                Text("之後每次都答對").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            GeometryReader { geo in
                let w = geo.size.width
                // Positions as fractions of the width; labels centre on their dots.
                let xs: [CGFloat] = [0.24, 0.41, 0.58, 0.79]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Palette.hairline).frame(width: w - 18, height: 2).offset(x: 7, y: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Circle().fill(Palette.warn).frame(width: 14, height: 14).frame(height: 22)
                        Text("再練一次").appFont(12, .bold, relativeTo: .caption1).foregroundStyle(Palette.warn)
                            .fixedSize()
                    }
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, label in
                        VStack(spacing: 6) {
                            Circle().strokeBorder(Palette.chart, lineWidth: 3)
                                .background(Circle().fill(Palette.card))
                                .frame(width: 14, height: 14).frame(height: 22)
                            Text(label).appFont(12, .medium, relativeTo: .caption1).fixedSize()
                        }
                        .frame(width: 60)
                        .offset(x: w * xs[i] - 30)
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.accent))
                        Text("熟練").appFont(12, .bold, relativeTo: .caption1).foregroundStyle(Palette.accent).fixedSize()
                    }
                    .frame(width: w, alignment: .trailing)
                }
            }
            .frame(height: 54)
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                Text("中途答錯，縮回一兩天後再出")
            }
            .appFont(12, relativeTo: .caption1)
            .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("答錯的題：今天隔 3 題再出一次，之後大約明天、2 天、6 天、17 天後複習，間隔夠長就算熟練；中途答錯，縮回一兩天後再出")
    }
}

/// 設定 › 複習怎麼排: FSRS in one line plus six questions and answers.
struct ReviewRulesView: View {
    /// Shown in a sheet (close button) instead of pushed (back button).
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if onClose == nil {
                        BackButton(label: "返回設定") { dismiss() }.padding(.leading, -10)
                    }
                    Spacer()
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("關閉")
                        .padding(.trailing, -10)
                    }
                }
                Text("複習怎麼排").headingFont(30)
                Text("排程採用 FSRS（開源的間隔重複記憶模型）：依你每題的作答紀錄估計記得多牢，在快要忘記前安排下一次複習。")
                    .appFont(15).lineSpacing(5).foregroundStyle(Palette.muted)
                qa("答錯或按「看解答」會怎樣？", "這題會排進複習：今日練習中隔 3 題再出一次，明天再複習。模擬考答錯的題也一樣。")
                VStack(alignment: .leading, spacing: 10) {
                    Text("間隔怎麼拉長？").appFont(16, .bold)
                    ReviewIntervalDiagram()
                    Text("每次到期那天答對，間隔就拉長；上面的天數是每次都答對時的大約值。")
                        .appFont(14, relativeTo: .subheadline).lineSpacing(4).foregroundStyle(Palette.muted)
                }
                .cardStyle()
                qa("第一次就答對呢？", "沒勾「猜的」的題是確認題：大約 8 天後再出一次，確認不是猜對的；再答對，間隔就拉得很長，答錯就變成錯題。確認題不算錯題、不進錯題本。勾了「猜的」就當錯題，明天再出，間隔也拉長得比較慢。")
                qa("確認題會不會太多？", "每天最多占每日題數的 1/3（20 題是 7 題），多的往後延，不會不見；考前一個月起不限。")
                qa("什麼算熟練？", "連續答對至少 2 次，而且下一次間隔在 3 週以上。再答錯就回到待複習。")
                qa("設了考試日期會怎樣？", "間隔較長的題會提前，最晚在考前 3 天複習；考前 14 天起，還沒熟練的錯題和確認題每天出。")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("reviewRules")
    }

    private func qa(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(q).appFont(16, .bold).accessibilityAddTraits(.isHeader)
            Text(a).appFont(14, relativeTo: .subheadline).lineSpacing(4).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

/// One-time 「0.3.3 版新功能」 sheet for people who finished onboarding before 0.3.3 (never shown to a first run). A person
/// who skipped 0.3.2 (`includesZeroThreeTwo`) also gets the 0.3.2 items, under their own subheading.
struct WhatsNewSheet: View {
    var includesZeroThreeTwo = false
    let onDone: () -> Void
    @State private var showHelp = false

    static let shownKey = OnboardingFlow.whatsNewKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("0.3.3 版新功能").appFont(13, .medium, relativeTo: .footnote).foregroundStyle(Palette.accent)
                        Text("這次更新了什麼").headingFont(26).accessibilityAddTraits(.isHeader)
                    }
                    item("calendar", "今日頁改版",
                         "打開就看到今天的題數、距離考試的天數和五科進度。一顆按鈕開始今天的題目；很少練的科目會標出來，按「練這科」直接練。")
                    item("checkmark.arrow.trianglehead.counterclockwise", "第一次答對也會再確認",
                         "第一次就答對的題目，約一週後會再出現一次確認（作答時標「下次確認」）。這些題不會進錯題本。")
                    item("ipad.landscape", "iPad 作答",
                         "iPad 視窗夠寬時，作答頁下方的按鈕列縮成一排，解析可以多看一些。「最該補的考點」會標出每個考點有幾題 AI 題。")
                    if includesZeroThreeTwo {
                        Text("0.3.2 版的更新").appFont(18, .bold).accessibilityAddTraits(.isHeader)
                            .padding(.top, 8)
                        zeroThreeTwoItems
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .readableScrollWidth()
            VStack(spacing: 4) {
                Button("知道了", action: onDone)
                    .buttonStyle(PrimaryButtonStyle(height: 52))
                Button("看使用說明") { showHelp = true }
                    .appFont(16, .medium)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .readableBarWidth()
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showHelp) {
            HelpView(onClose: { showHelp = false })
        }
        .trackScreen("whatsNew")
    }

    @ViewBuilder private var zeroThreeTwoItems: some View {
        item("text.bubble", "問講義",
             "講義頁可以「問這份講義」，每個考點可以「問這個考點」，看不懂的地方直接問 AI。一次對話最多 5 輪，回答會標「AI 產生，請對照課本」。",
             tone: .notice)
        item("info.circle", "畫面更清爽",
             "各頁的說明文字精簡了，細節收進 ⓘ 按鈕，第一次進畫面才提示一次；完整規則都在「設定 › 使用說明」。")
        item("arrow.triangle.2.circlepath", "連線更穩",
             "主伺服器暫時連不上時，會自動改連備用伺服器。")
    }

    private enum Tone { case plain, notice }

    private func item<Extra: View>(_ icon: String, _ title: String, _ text: String, tone: Tone = .plain,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone == .notice ? Palette.noticeInk : Palette.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(tone == .notice ? Palette.notice : Palette.accentSoft))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).appFont(16, .bold)
                // The notice badge sits between the title and the text; other extras follow the text.
                if tone == .notice { extra() }
                Text(text).appFont(14, relativeTo: .subheadline).lineSpacing(4).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if tone != .notice { extra() }
            }
        }
    }

    private func item(_ icon: String, _ title: String, _ text: String, tone: Tone = .plain) -> some View {
        item(icon, title, text, tone: tone) { EmptyView() }
    }
}
