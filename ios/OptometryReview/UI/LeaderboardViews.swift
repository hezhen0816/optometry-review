import SwiftUI

/// Navigation values inside the 成績 stack.
enum LeaderboardRoute: Hashable {
    case board
    case member(LeaderboardEntry)
    case settings
}

/// Monday–Sunday of this week in Taipei, for the header before the server answers.
private func localWeekLabel(now: Date = .now) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
    cal.firstWeekday = 2
    guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start,
          let end = cal.date(byAdding: .day, value: 6, to: start) else { return "" }
    let a = cal.dateComponents([.month, .day], from: start), b = cal.dateComponents([.month, .day], from: end)
    return "\(a.month ?? 0)/\(a.day ?? 0) – \(b.month ?? 0)/\(b.day ?? 0)"
}

// MARK: - 成績 row

/// Slim row at the top of 成績: how many days I practiced this week, or how to take part.
struct LeaderboardEntryRow: View {
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @AppStorage(LeaderboardModel.joinedKey) private var joined = false
    private let model = LeaderboardModel.shared

    var body: some View {
        NavigationLink(value: LeaderboardRoute.board) {
            HStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                (Text("讀書夥伴").bold() + Text(" ・ ").foregroundColor(Palette.muted) + status)
                    .appFont(15, relativeTo: .subheadline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .task(id: usageEnabled && joined) {
            if usageEnabled && joined { await model.refresh() } else { await model.retryPendingLeave() }
        }
    }

    private var status: Text {
        if !usageEnabled || !joined {
            return Text(usageEnabled ? "加入讀書夥伴" : "未開啟").foregroundColor(Palette.muted)
        } else if let me = model.board?.mine {
            return Text("本週你練了 \(me.days) 天").foregroundColor(Palette.muted)
        } else {
            return Text(model.error == nil ? "本週" : "暫時讀不到").foregroundColor(Palette.muted)
        }
    }
}

// MARK: - Bars

/// Monday–Sunday correct counts: a mini strip on the cards, larger with numbers on a partner's page.
/// Future days are dashed placeholders; `daily == nil` (still loading) shows flat bars and no spoken claim.
struct WeekBars: View {
    let daily: [Int]?
    let today: Int?
    var large = false
    static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        let values = daily ?? []
        let peak = max(1, values.max() ?? 1)
        let area: CGFloat = large ? 80 : 34
        HStack(alignment: .bottom, spacing: large ? 8 : 4) {
            ForEach(Self.weekdays.indices, id: \.self) { i in
                let future = today.map { i > $0 } ?? false
                let n = i < values.count ? values[i] : 0
                VStack(spacing: 4) {
                    if large { Text(future || daily == nil ? " " : "\(n)").appFont(11, relativeTo: .caption2).monospacedDigit() }
                    Group {
                        if future {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Palette.chipBorder, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .frame(height: 6)
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(n > 0 ? (i == today ? Palette.accent : Palette.chart.opacity(0.55)) : Palette.segmentTrack)
                                .frame(height: max(n > 0 ? 4 : 3, CGFloat(n) / CGFloat(peak) * area))
                        }
                    }
                    Text(Self.weekdays[i]).appFont(11, i == today ? .bold : .regular, relativeTo: .caption2)
                        .foregroundStyle(i == today ? Palette.ink : Palette.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: area + (large ? 38 : 22), alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(daily == nil ? "" : "本週每天答對：\(spoken(values))")
        .accessibilityHidden(daily == nil)
    }

    private func spoken(_ values: [Int]) -> String {
        Self.weekdays.indices.map { i -> String in
            if let today, i > today { return "週\(Self.weekdays[i]) 還沒到" }
            return "週\(Self.weekdays[i]) \(i < values.count ? values[i] : 0) 題"
        }.joined(separator: "、")
    }
}

// MARK: - Main page

struct LeaderboardView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @AppStorage(LeaderboardModel.joinedKey) private var joined = false
    @State private var showJoin = false
    private let model = LeaderboardModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !usageEnabled {
                    offCard(title: "讀書夥伴需要開啟「使用紀錄回傳」",
                            text: "夥伴的本週紀錄由伺服器依回傳的作答紀錄計算。開啟並確認顯示名稱、加入之後，才看得到讀書夥伴。",
                            button: "到設定開啟", route: .settings)
                } else if !joined {
                    offCard(title: "你沒有參加讀書夥伴",
                            text: "參加後才看得到夥伴的本週紀錄；別人會看到哪些資料，按「參加」會先說明。",
                            button: "參加", route: nil)
                } else if let board = model.board {
                    cards(board)
                    notes(alone: board.entries.count < 2)
                } else if let error = model.error {
                    errorCard(error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        .refreshable { await refresh() }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("leaderboard")
        .task(id: usageEnabled && joined) {
            if usageEnabled && joined { await refresh() }
        }
        .onAppear {
            if usageEnabled && !joined && !model.prompted { showJoin = true }
        }
        .sheet(isPresented: $showJoin) {
            LeaderboardJoinSheet()
        }
    }

    private func refresh() async {
        await model.refresh()
        await model.loadDailies()
    }

    private var topBar: some View {
        HStack {
            BackButton(label: "返回成績") { dismiss() }
            Spacer()
            NavigationLink(value: LeaderboardRoute.settings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("讀書夥伴設定")
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .padding(.vertical, 4)
        .background(Palette.ground.ignoresSafeArea(edges: .top))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("讀書夥伴").headingFont(30)
                InfoButton(title: "夥伴看得到什麼",
                           text: "夥伴看得到你的天數、答對題數與每天各科的答對；看不到正確率、錯了哪些題、作答內容和模擬考分數。")
                Spacer(minLength: 0)
            }
            Text("本週 \(model.board?.week?.label ?? localWeekLabel())")
                .appFont(13, relativeTo: .footnote)
                .foregroundStyle(Palette.muted)
        }
    }

    private func offCard(title: String, text: String, button: String, route: LeaderboardRoute?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(title).appFont(17, .bold).multilineTextAlignment(.center)
            Text(text).appFont(14, relativeTo: .subheadline).lineSpacing(4).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let route {
                    NavigationLink(button, value: route)
                } else {
                    Button(button) { showJoin = true }
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 50))
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    private func errorCard(_ error: LeaderboardError) -> some View {
        VStack(spacing: 10) {
            Text(error.message).appFont(15).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            Button("再試一次") { Task { await refresh() } }
                .appFont(15, .bold)
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    /// Two columns: two people sit side by side, three or more wrap into a grid. Me first, then by name.
    private func cards(_ board: LeaderboardBoard) -> some View {
        let today = board.week?.dayIndex(of: .now)
        let list = board.ordered
        let rows = stride(from: 0, to: list.count, by: 2).map { Array(list[$0..<min($0 + 2, list.count)]) }
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { e in
                        BuddyCard(entry: e, daily: model.dailies[e.id], today: today, lastWeekCorrect: board.lastWeekCorrect)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    if rows[r].count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func notes(alone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if alone {
                Text("還沒有其他人加入。請朋友到「成績 › 讀書夥伴」加入，就會出現在這裡。")
                    .appFont(13, relativeTo: .footnote).lineSpacing(3).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            }
        }
    }
}

/// One person's card: days, correct count, mini week strip. Only mine carries the week-over-week line and accuracy.
struct BuddyCard: View {
    let entry: LeaderboardEntry
    let daily: [Int]?
    let today: Int?
    let lastWeekCorrect: Int?

    var body: some View {
        if entry.me {
            content
        } else {
            NavigationLink(value: LeaderboardRoute.member(entry)) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(entry.name).appFont(16, .bold).lineLimit(1)
                if entry.me {
                    Text("我").appFont(11, .bold, relativeTo: .caption2)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accent))
                }
                Spacer(minLength: 0)
                if !entry.me {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted).accessibilityHidden(true)
                }
            }
            stat("本週練了", "\(entry.days)", unit: "／\(WeeklyGoal.targetDays) 天")
            stat("本週答對", "\(entry.correct)", unit: " 題")
            WeekBars(daily: daily, today: today)
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).appFont(26, .bold, relativeTo: .title2).monospacedDigit()
                Text(unit).appFont(13).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        if entry.me {
            let week = LeaderboardText.weekOverWeek(this: entry.correct, last: lastWeekCorrect)
            let accuracy = LeaderboardText.ownAccuracyLine(entry)
            if week != nil || accuracy != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let week { Text(week).appFont(13, .bold, relativeTo: .footnote) }
                    if let accuracy {
                        Text(accuracy).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - Join sheet

/// First open: confirm the display name; nobody is listed before 「加入」.
struct LeaderboardJoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = LeaderboardModel.shared.savedName
    @State private var busy = false
    @State private var error: LeaderboardError?
    @FocusState private var focused: Bool
    /// Measured content and button heights: the sheet fits them instead of opening full height.
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    private let model = LeaderboardModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("加入讀書夥伴").headingFont(24)
                    Text("和朋友互看本週練了幾天、答對幾題，不排名次、不比較；每週一 00:00 重新計算，練習和模擬考的答對都算，重做同一題也算。")
                        .appFont(15).lineSpacing(4).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("其他參加的人會看到").appFont(14, .bold)
                        Text("顯示名稱、本週練了幾天（N／5）、本週答對題數，以及你本週每天和各科的答對題數。看不到你的正確率、錯了哪些題、作答內容和模擬考分數。")
                            .appFont(13, relativeTo: .footnote).lineSpacing(3).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("按「加入」才會出現").appFont(14, .bold).padding(.top, 6)
                        Text("在那之前你不會出現在別人的畫面；沒參加的人也看不到讀書夥伴。之後可到「設定 › 讀書夥伴」關掉，就會從別人的畫面移除。")
                            .appFont(13, relativeTo: .footnote).lineSpacing(3).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("顯示名稱").appFont(13, .medium, relativeTo: .footnote).foregroundStyle(Palette.muted)
                        TextField("輸入名字", text: $name)
                            .appFont(17)
                            .focused($focused)
                            .submitLabel(.done)
                            .textContentType(.nickname)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(focused ? Palette.accent : Palette.border, lineWidth: focused ? 1.5 : 1))
                            .onChange(of: name) { _, v in
                                if v.count > LeaderboardText.maxNameLength { name = String(v.prefix(LeaderboardText.maxNameLength)) }
                            }
                        Text("取一個朋友認得的名字，之後也能在設定改。")
                            .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                        if let error {
                            Text(error.message).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.warn)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .readableScrollWidth()
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 2) {
                Button(action: join) {
                    if busy { ProgressView().tint(Palette.onAccent) } else { Text("加入") }
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))
                .disabled(busy || LeaderboardText.validName(name) == nil)
                Button("先不要") {
                    model.markPrompted()
                    dismiss()
                }
                .appFont(16, .medium)
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0 }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight + footerHeight)] : [.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .interactiveDismissDisabled(busy)
        .trackScreen("leaderboardJoin")
        .onDisappear { model.markPrompted() }
    }

    private func join() {
        Haptics.selection()
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.join(name: name)
                dismiss()
            } catch let e as LeaderboardError {
                error = e
            } catch {}
        }
    }
}

// MARK: - Member

/// One partner's week: daily bars, per-subject counts. Never their accuracy, mistakes, answers or mock scores.
struct LeaderboardMemberView: View {
    let entry: LeaderboardEntry

    @Environment(\.dismiss) private var dismiss
    @State private var member: LeaderboardMember?
    @State private var error: LeaderboardError?
    private let model = LeaderboardModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(member?.name ?? entry.name).headingFont(30).lineLimit(2)
                    Text("本週 \(model.board?.week?.label ?? localWeekLabel())")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                }
                tiles
                if let member {
                    dailyCard(member)
                    subjectCard(member)
                } else if let error {
                    Text(error.message).appFont(15).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    Text("正確率與作答內容雙方都看不到")
                        .appFont(12, relativeTo: .caption1).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: "返回讀書夥伴") { dismiss() }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("leaderboardMember")
        .task {
            do {
                member = try await model.member(id: entry.id)
            } catch let e as LeaderboardError {
                error = e
            } catch {}
        }
    }

    private var tiles: some View {
        let correct = member?.correct ?? entry.correct
        let days = member?.days ?? entry.days
        return HStack(alignment: .top, spacing: 8) {
            tile("本週練了", "\(days)", unit: "／\(WeeklyGoal.targetDays) 天")
            tile("本週答對", "\(correct)", unit: " 題")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    private func tile(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).appFont(32, .bold, relativeTo: .largeTitle).monospacedDigit()
                Text(unit).appFont(14).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func dailyCard(_ m: LeaderboardMember) -> some View {
        let today = model.board?.week?.dayIndex(of: .now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("本週每天答對").appFont(15, .bold)
                Spacer()
                if let today { Text("今天：週\(WeekBars.weekdays[today])").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted) }
            }
            WeekBars(daily: m.daily, today: today, large: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func subjectCard(_ m: LeaderboardMember) -> some View {
        let total = m.subjects.values.reduce(0, +)
        let peak = max(1, m.subjects.values.max() ?? 1)
        let order = Subjects.all + m.subjects.keys.filter { !Subjects.all.contains($0) }.sorted()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("各科本週答對").appFont(15, .bold)
                Spacer()
                Text("共 \(total) 題").appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
            }
            ForEach(order, id: \.self) { s in
                let n = m.subjects[s] ?? 0
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(s).appFont(14, relativeTo: .subheadline)
                        Spacer()
                        Text("\(n) 題").appFont(14, relativeTo: .subheadline).monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.segmentTrack)
                            Capsule().fill(Palette.chart).frame(width: geo.size.width * CGFloat(n) / CGFloat(peak))
                        }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}
