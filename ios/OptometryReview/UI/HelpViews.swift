import SwiftUI

// 使用說明 (0.3.0, design Ob03Help / Ob03HelpPad). Content lives in `HelpContent`; the iPhone list expands one card
// per topic, the iPad landscape layout shows the topic list on the left and one topic on the right.

enum HelpBlock {
    case heading(String)
    case paragraph(String)
    /// Numbered steps.
    case steps([String])
    /// Muted small print.
    case note(String)
    /// Label plus explanation, one per row.
    case terms([HelpTerm])
}

struct HelpTerm {
    enum Style { case plain, official, ai }
    let label: String
    var style: Style = .plain
    let text: String
}

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    var blocks: [HelpBlock] = []
    /// 複習怎麼排 opens its own page instead of expanding.
    var opensRules = false
}

struct HelpGroup: Identifiable {
    let title: String
    let topics: [HelpTopic]
    var id: String { title }
}

enum HelpContent {
    static let groups: [HelpGroup] = [
        HelpGroup(title: "開始", topics: [daily]),
        HelpGroup(title: "分頁", topics: [today, units, mistakes, exam, stats]),
        HelpGroup(title: "作答", topics: [answering]),
        HelpGroup(title: "規則", topics: [rules, official, mastery]),
        HelpGroup(title: "資料與裝置", topics: [sync, backup, usage, updates]),
    ]

    static var topics: [HelpTopic] { groups.flatMap(\.topics) }

    static let daily = HelpTopic(id: "daily", title: "每天怎麼用", blocks: [
        .steps([
            "打開「今日」按大卡片下方的大按鈕，練完今天的題：到期的錯題先出，不夠再補新題。想只練一科，在「五科進度」按「練這科」。",
            "「最該補的考點」列出的考點，點進去讀那段講義，再練這個考點。",
            "讀新範圍時到「單元」：先讀重點講義，再練歷屆題；計算題考點可以加練 AI 題。",
            "練完一輪，按「檢討這回」看這輪搞混了哪些考點。",
            "讀完一科，到「模擬考」考一份單科模擬，再到「成績」看推估。",
        ]),
        .note("每晚會依你的作答更新「最該補的考點」，需要開著「使用紀錄回傳」。"),
    ])

    static let today = HelpTopic(id: "today", title: "今日", subtitle: "今天的目標、調整範圍與題數、最該補的考點", blocks: [
        .paragraph("大卡片是今天的目標：答對設定的題數就達標。按下方的大按鈕先出到期的錯題，不夠再補新題。"),
        .paragraph("「五科進度」顯示每科做過幾題，按「練這科」只練那一科。"),
        .paragraph("卡片上的「調整」可以改今天練哪些科目、年份和題數；「自選練習」自己挑範圍練。"),
        .paragraph("「最該補的考點」最多列 3 個，點進去讀那段講義。每晚分析後，每列多一行標「AI 分析」的理由。"),
        .note("最上方的日期列有距考試的天數和本週練了幾天，右側進設定。"),
    ])

    static let units = HelpTopic(id: "units", title: "單元與重點講義", subtitle: "考點、掌握度、你的筆記、自我小測、練 AI 題", blocks: [
        .paragraph("五科依考選部命題大綱分成單元。點科目展開，每個單元一行三個數字：歷屆題數、AI 題數、你的錯題數。"),
        .paragraph("點單元進單元頁：重點講義、考點卡片，以及「練歷屆題」「練 AI 題」。只有計算題的考點有 AI 題。"),
        .paragraph("重點講義有一眼看懂、考點整理、易錯陷阱和自我小測（答案按「顯示答案」才出現）。做過題後，考點最上方多一張「你的筆記」。講義和筆記都標「AI 產生，請對照課本」。"),
        .paragraph("每個考點標掌握度：待加強、還不穩、穩定、沒做過，旁邊寫「錯 x／做 y」。"),
        .note("右上的年份按鈕可以只看某幾年的題目。"),
    ])

    static let mistakes = HelpTopic(id: "mistakes", title: "錯題本", subtitle: "篩選、AI 錯題、收藏的題目與筆記", blocks: [
        .paragraph("答錯的歷屆題自動收進來。可依科目、年份、單元、錯因篩選，套用的條件列在「篩選」旁，點一下就移除；底部「練這 N 題」練目前篩選的題。"),
        .paragraph("上方切到「AI 錯題」看答錯的 AI 題：再答對一次就移出。它們不進每日複習，也不算進歷屆的錯題數。"),
        .paragraph("☆ 收藏分「歷屆｜AI 題｜AI 筆記」：收藏的題目，和按「收藏這份筆記」留下的筆記。"),
        .paragraph("不想再練的題可以「移出複習」，放進「不用再練」，之後能移回。"),
    ])

    static let exam = HelpTopic(id: "exam", title: "模擬考與歷屆試卷", subtitle: "單科模擬、五科連考、原始試卷", blocks: [
        .paragraph("單科模擬每份 50 題、60 分鐘，可選整份歷屆、隨機混合或錯題加強。五科連考每科 50 題 60 分鐘，科間休息 10 分鐘，照正式考試連考五科。"),
        .paragraph("作答中不顯示對錯，交卷後看成績；答錯的題也會排進複習。"),
        .paragraph("「歷屆試卷」是 106～115 年考選部原始試卷，依年份看整份原卷或逐題練。特考是給已執業者的考試，預設不出，可在設定開啟「納入特考試題」。"),
    ])

    static let stats = HelpTopic(id: "stats", title: "成績", subtitle: "及格推估、單科分析、學習紀錄、讀書夥伴", blocks: [
        .paragraph("交過的模擬考畫成走勢，照國考及格規則推估「推估及格／未達」。AI 題不算進推估。"),
        .paragraph("往下看單科分析、考點掌握度和學習紀錄（本週練了幾天）。"),
        .paragraph("讀書夥伴在最上方：和朋友互看本週練了幾天、答對幾題，不排名次。第一次要確認顯示名稱、按「加入」才會出現，可隨時在設定關閉。"),
    ])

    static let answering = HelpTopic(id: "answering", title: "作答時的按鈕", subtitle: "看解答、猜的、再練一次、錯因、收藏、題目有誤", blocks: [
        .terms([
            HelpTerm(label: "看解答", text: "作答前直接看答案，算答錯並排進複習。"),
            HelpTerm(label: "猜的", text: "答對但沒把握時勾：這題當錯題排進複習，明天再出。沒勾的答對題約 8 天後再出一次確認（確認題），不算錯題。"),
            HelpTerm(label: "再練一次", text: "今日練習答錯的題，隔 3 題會再出現。"),
            HelpTerm(label: "錯因", text: "答錯後可以標錯在哪，之後能用錯因篩選錯題本。"),
            HelpTerm(label: "☆ 收藏", text: "收藏這題，到錯題本的 ☆ 看。"),
            HelpTerm(label: "⋯ 題目有誤", text: "覺得題目或答案有問題時回報；AI 題的圖畫錯了，按圖下方的「圖有誤」。"),
            HelpTerm(label: "AI 解析", style: .ai, text: "作答後可看；答錯時、iPad 橫放時會自動展開。答案一律以官方為準。"),
        ]),
    ])

    static let rules = HelpTopic(id: "rules", title: "複習怎麼排", subtitle: "錯題什麼時候再出、什麼算熟練", opensRules: true)

    static let official = HelpTopic(id: "official", title: "官方題與 AI 內容", blocks: [
        .paragraph("題目和答案以考選部公布的為準，有更正答案時以更正為準。AI 可能出錯，和課本不同時以課本和官方答案為準。"),
        .terms([
            HelpTerm(label: "歷屆", style: .official, text: "考選部原題。算進正確率、錯題本、每日複習、模擬考、及格推估和讀書夥伴。"),
            HelpTerm(label: "AI 出題，非官方・AI 自動檢核", style: .ai,
                     text: "AI 照歷屆計算題的算法換數字出的題；答案由程式依公式算出，再由 AI 不看答案另解一次，一致才收。只算一半進考點掌握度；答錯放「錯題本 › AI 錯題」，不進每日複習。"),
            HelpTerm(label: "AI 產生，請對照課本", style: .ai, text: "整塊由 AI 寫的內容：重點講義、AI 解析、你的筆記、檢討這回。"),
            HelpTerm(label: "AI 分析", style: .ai, text: "夾在一般內容裡的一行 AI 說明，例如「最該補的考點」旁的理由。"),
            HelpTerm(label: "圖解 ・ 依題目參數繪製、已驗算",
                     text: "AI 題的圖由程式照題目數字畫，不是 AI 畫的；畫錯按「圖有誤」。題目本身有問題按「⋯ › 題目有誤」。"),
        ]),
    ])

    static let mastery = HelpTopic(id: "mastery", title: "掌握度和熟練", subtitle: "考點的待加強、還不穩、穩定；單題的熟練", blocks: [
        .paragraph("考點的掌握度有四種：待加強、還不穩、穩定、沒做過。旁邊只寫次數「錯 3／做 4」，不顯示百分比。AI 題算一半。"),
        .paragraph("單題的「熟練」：連續答對至少 2 次，而且下一次間隔在 3 週以上。再答錯就回到待複習。"),
    ])

    static let sync = HelpTopic(id: "sync", title: "iPhone 與 iPad 同步", subtitle: "同步什麼、狀態怎麼看、第一次加入", blocks: [
        .heading("同步什麼"),
        .paragraph("作答紀錄、錯題排程、筆記、收藏和模擬考；考試日期、每日題數、今日範圍、特考和新題比例，以及看過的提示也一起改。自選練習上次的選擇，各台自己記。"),
        .heading("怎麼開始"),
        .paragraph("兩台登入同一個 Apple 帳號並開著 iCloud，就會自動同步，不用按任何按鈕。"),
        .heading("第二台第一次打開"),
        .paragraph("如果兩台都已經有作答，會問一次：「改用 iCloud 上的紀錄」（這台原本的紀錄先存成匯出檔，之後可在「設定 › 資料」加回來），或「合併兩邊」（兩台的作答全部保留）。每台只問一次。"),
        .paragraph("兩台都有裝時，先更新 iPhone、打開一次，等「設定 › 資料 › iCloud 同步」顯示已同步，再更新 iPad。"),
        .heading("看同步狀態"),
        .paragraph("「設定 › 資料 › iCloud 同步」右側會寫："),
        .terms([
            HelpTerm(label: "已同步", text: "兩台一致。"),
            HelpTerm(label: "同步中", text: "正在傳，稍等即可。"),
            HelpTerm(label: "等待網路", text: "連上網路後自動繼續。"),
            HelpTerm(label: "未登入 iCloud", text: "到 iOS「設定」登入 Apple 帳號並開啟 iCloud。"),
            HelpTerm(label: "iCloud 空間不足", text: "先存在這台，清出空間後自動繼續。"),
            HelpTerm(label: "目前無法同步", text: "資料仍在這台，會自動再試。"),
        ]),
    ])

    static let backup = HelpTopic(id: "backup", title: "匯出與匯入", subtitle: "換手機或重裝前後，怎麼保留作答紀錄", blocks: [
        .paragraph("「設定 › 資料 › 匯出作答紀錄」存成檔案；換手機或重裝後，用「匯入作答紀錄」選回那個檔案。"),
        .paragraph("匯入只加入沒有的資料，已有的資料不會被刪除或覆蓋；確認畫面會先寫出會加入多少。"),
    ])

    static let usage = HelpTopic(id: "usage", title: "使用紀錄回傳", subtitle: "傳了什麼、用來做什麼、怎麼關", blocks: [
        .paragraph(UsageDisclosure.full),
        .note("每晚的弱點分析和讀書夥伴需要開著；開關在「設定 › 資料」。"),
    ])

    static let updates = HelpTopic(id: "updates", title: "更新提示", subtitle: "今日最上方的橫幅、怎麼到 TestFlight 更新", blocks: [
        .paragraph("有新版本時，今日最上方會出現一條橫幅，點了開 TestFlight 更新，可以按右側 ✕ 先關掉。"),
        .paragraph("橫幅寫「請更新到新版本」表示舊版的部分功能可能無法使用，這種不能關。"),
    ])
}

/// 設定 › 使用說明. Pushed from 設定 (back button) or shown in a sheet (`onClose`).
struct HelpView: View {
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = [HelpContent.daily.id]
    @State private var selected = HelpContent.daily.id
    @State private var width: CGFloat = 0
    @State private var showTour = false
    @State private var showRules = false

    /// iPad landscape (design Ob03HelpPad): topic list | one topic.
    private var twoColumns: Bool { width >= Layout.threeColumnWidth }

    var body: some View {
        Group {
            if twoColumns { padLayout } else { phoneLayout }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .fullScreenCover(isPresented: $showTour) { TourView(mode: .replay) }
        .sheet(isPresented: $showRules) { ReviewRulesView(onClose: { showRules = false }) }
        .trackScreen("help")
    }

    // MARK: iPhone

    private var phoneLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                topBar
                Text("使用說明").headingFont(30).accessibilityAddTraits(.isHeader)
                Text("每個功能怎麼用、什麼時候用。點標題展開。")
                    .appFont(14, relativeTo: .subheadline).lineSpacing(3).foregroundStyle(Palette.muted)
                    .padding(.bottom, 6)
                tourButton
                ForEach(HelpContent.groups) { group in
                    Text(group.title).appFont(13, .medium, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        .padding(.leading, 4).padding(.top, 10)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.topics) { topic in card(topic) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
    }

    private var topBar: some View {
        HStack {
            if let onClose {
                Spacer()
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
            } else {
                BackButton(label: "返回設定") { dismiss() }.padding(.leading, -10)
                Spacer()
            }
        }
    }

    private var tourButton: some View {
        Button { showTour = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.onAccent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("看導覽").appFont(16, .bold)
                    Text("\(TourPage.count) 頁：五個分頁、怎麼複習、AI 標示、同步")
                        .appFont(13, relativeTo: .footnote).opacity(0.9)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card(_ topic: HelpTopic) -> some View {
        let open = expanded.contains(topic.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.selection()
                if topic.opensRules { showRules = true; return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    if open { expanded.remove(topic.id) } else { expanded.insert(topic.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title).appFont(16, .bold).multilineTextAlignment(.leading)
                        if let subtitle = topic.subtitle, !open {
                            Text(subtitle).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: topic.opensRules ? "chevron.right" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(topic.opensRules ? "" : (open ? "已展開" : "已收合"))
            if open {
                HelpBlocksView(blocks: topic.blocks)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    // MARK: iPad landscape

    private var padLayout: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    topBar
                    Text("使用說明").headingFont(28).accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 8)
                    tourButton.padding(.bottom, 6)
                    ForEach(HelpContent.groups) { group in
                        Text(group.title).appFont(13, .medium, relativeTo: .footnote).foregroundStyle(Palette.muted)
                            .padding(.leading, 10).padding(.top, 12)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.topics) { topic in indexRow(topic) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .frame(width: 320)
            .background(Palette.card)
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
            ScrollView {
                if let topic = HelpContent.topics.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(topic.title).headingFont(30).accessibilityAddTraits(.isHeader)
                        HelpBlocksView(blocks: topic.blocks, padding: true)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func indexRow(_ topic: HelpTopic) -> some View {
        let on = selected == topic.id && !topic.opensRules
        return Button {
            Haptics.selection()
            if topic.opensRules { showRules = true } else { selected = topic.id }
        } label: {
            HStack {
                Text(topic.title).appFont(15, on ? .bold : .regular)
                    .foregroundStyle(on ? Palette.accent : Palette.ink)
                Spacer(minLength: 0)
                if topic.opensRules {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The blocks of one help topic.
struct HelpBlocksView: View {
    let blocks: [HelpBlock]
    /// iPad detail pane: slightly larger text.
    var padding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).appFont(17, .bold).padding(.top, 6).accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text(text).appFont(padding ? 15 : 14, relativeTo: .subheadline).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                case .note(let text):
                    Text(text).appFont(13, relativeTo: .footnote).lineSpacing(4).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                case .steps(let steps):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(i + 1)").appFont(12, .bold, relativeTo: .caption1)
                                    .foregroundStyle(Palette.accent)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Palette.accentSoft))
                                    .padding(.top, 1)
                                Text(step).appFont(14, relativeTo: .subheadline).lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .terms(let terms):
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                            VStack(alignment: .leading, spacing: 4) {
                                termLabel(term)
                                Text(term.text).appFont(14, relativeTo: .subheadline).lineSpacing(4)
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func termLabel(_ term: HelpTerm) -> some View {
        switch term.style {
        case .plain:
            Text(term.label).appFont(14, .bold)
        case .official:
            Text(term.label).appFont(11, .bold, relativeTo: .caption2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(Palette.accent)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.accentSoft))
        case .ai:
            Text(term.label).appFont(11, .bold, relativeTo: .caption2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(Palette.noticeInk)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.notice))
        }
    }
}
