import SwiftUI
import SwiftData

/// Numbers for 學習紀錄, computed once per appearance.
struct StudyLogSummary {
    var week: [WeeklyGoal.Day]
    /// Days this week with any answer (the weekly target counts these).
    var daysStudied: Int
    var activity: StudyTime.Summary
    var cells: [StudyHeatmap.Cell]
    var heatmapTotal: Int
    var accuracy: AccuracySplit.Result
    var digest: MistakeDigest

    static let accuracyDays = 30

    @MainActor
    static func load(context: ModelContext, goal: Int, bank: QuestionBank? = nil, includeSpecial: Bool = false,
                     now: Date = .now, calendar: Calendar = .current) -> StudyLogSummary {
        let store = StudyStore(context: context)
        let facts = store.attemptFacts()
        let week = WeeklyGoal.week(attempts: facts, goal: goal, now: now, calendar: calendar)
        let cells = StudyHeatmap.cells(counts: StudyHeatmap.counts(facts, calendar: calendar), goal: goal, now: now, calendar: calendar)
        let since = calendar.date(byAdding: .day, value: -accuracyDays, to: calendar.startOfDay(for: now))!
        return StudyLogSummary(week: week, daysStudied: week.filter(\.studied).count,
                               activity: store.studyActivity(now: now), cells: cells,
                               heatmapTotal: cells.map(\.count).reduce(0, +),
                               accuracy: AccuracySplit.compute(facts, since: since),
                               digest: bank.map { digest(store: store, bank: $0, includeSpecial: includeSpecial, now: now) }
                                   ?? store.mistakeDigest(now: now))
    }

    /// Same set as the 錯題本 list: scheduled mistakes in the active pool; 複習中 = its open mistakes.
    @MainActor
    static func digest(store: StudyStore, bank: QuestionBank, includeSpecial: Bool, now: Date) -> MistakeDigest {
        var d = MistakeDigest(mastered: 0, reviewing: 0)
        for r in store.allRecords() where r.schedule.isMistake {
            guard let q = bank.byID[r.questionID], q.examKind == ExamKind.general || includeSpecial else { continue }
            if r.isMastered(using: store.scheduler, at: now) { d.mastered += 1 } else { d.reviewing += 1 }
        }
        return d
    }
}

/// Sequential teal ramp for the heatmap. Text color per level keeps ≥ 4.5:1 (white only on the dark steps).
enum HeatRamp {
    static let fills: [Color] = [
        Palette.dynamic(0xE4E9E7, 0x26322F),
        Palette.dynamic(0xB9D7E3, 0x1E4350),
        Palette.dynamic(0x6FAFC9, 0x226983),
        Palette.dynamic(0x1F7598, 0x4A9DBD),
        Palette.dynamic(0x0E5674, 0x9AD0E4),
    ]
    /// Light: ink on 0–2, white on 3–4. Dark: light ink on 0–2, near-black on 3–4.
    static func text(_ level: Int) -> Color {
        level >= 3 ? Palette.dynamic(0xFFFFFF, 0x0F1715) : Palette.ink
    }
}

/// 學習紀錄: weekly goal (5 of 7 days, no streaks), five-week heatmap, accuracy split and mistake digestion.
struct StudyLogView: View {
    /// Pushed from 今日 or 成績.
    var backLabel = "返回今日"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @Environment(\.questionBank) private var bank

    @State private var summary: StudyLogSummary?
    @State private var grown = false

    private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton(label: backLabel) { dismiss() }
                    .padding(.leading, -10)
                Text("學習紀錄").headingFont(30)
                if let s = summary {
                    todayCard(s.activity)
                    weekCard(s)
                    heatmapCard(s)
                    accuracyCard(s.accuracy)
                    digestCard(s.digest)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("studyLog")
        .onAppear {
            summary = StudyLogSummary.load(context: context, goal: dailyGoal, bank: bank, includeSpecial: includeSpecial)
            if reduceMotion { grown = true } else {
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.4)) { grown = true } }
            }
        }
    }

    // MARK: Today

    private func todayCard(_ a: StudyTime.Summary) -> some View {
        let today = a.today
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天學習時間").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(today.minutes.rounded()))").appFont(40, .bold, relativeTo: .largeTitle).monospacedDigit()
                    Text("分").appFont(15).foregroundStyle(Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今天作答").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        // Attempts (a question answered twice counts twice); the heatmap below counts questions.
                        Text("\(today.answeredCount)").appFont(24, .bold, relativeTo: .title2).monospacedDigit()
                        Text("次").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    }
                    Text("新題 \(today.newAnsweredCount) ・ 複習 \(today.reviewAnsweredCount)")
                        .appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正確率").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(today.accuracy.map(String.init) ?? "—").appFont(24, .bold, relativeTo: .title2).monospacedDigit()
                        if today.accuracy != nil { Text("%").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if let focus = a.mostFocusedDay {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "star").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                    Text(focusText(focus)).appFont(13, relativeTo: .footnote).lineSpacing(3)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentSoft))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    /// 「過去一個月最專注的一天：9/15，40 分鐘做了 40 題」 (minutes left out under one minute).
    private func focusText(_ d: StudyTime.Day) -> String {
        let minutes = Int(d.minutes.rounded())
        let day = DateText.monthDay.string(from: d.date)
        let what = minutes > 0 ? "\(minutes) 分鐘做了 \(d.answeredCount) 題" : "做了 \(d.answeredCount) 題"
        return "過去一個月最專注的一天：\(day)，\(what)"
    }

    // MARK: Weekly goal

    private func weekCard(_ s: StudyLogSummary) -> some View {
        let reached = s.daysStudied >= WeeklyGoal.targetDays
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("本週目標").appFont(15, .bold)
                Spacer()
                Text(reached ? "本週達標" : "7 天中做 5 天")
                    .appFont(12, .bold, relativeTo: .caption1)
                    .foregroundStyle(reached ? Palette.accent : Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(s.daysStudied)").appFont(40, .bold, relativeTo: .largeTitle).monospacedDigit()
                Text("／\(WeeklyGoal.targetDays) 天").appFont(17).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("本週 \(s.daysStudied) 天有作答，目標 5 天")
            HStack(spacing: 6) {
                ForEach(Array(s.week.enumerated()), id: \.offset) { i, day in
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(day.goalMet ? Palette.accent : (day.studied ? Palette.accentSoft : Palette.card))
                            Circle().strokeBorder(day.isFuture ? Palette.chipBorder : (day.studied ? Palette.accent : Palette.border),
                                                  style: StrokeStyle(lineWidth: day.isToday ? 2 : 1, dash: day.isFuture ? [3, 3] : []))
                            if day.goalMet {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.onAccent)
                            }
                        }
                        .frame(width: 34, height: 34)
                        Text(Self.weekdays[i]).appFont(12, day.isToday ? .bold : .regular, relativeTo: .caption1)
                            .foregroundStyle(day.isToday ? Palette.ink : Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(dayLabel(day, weekday: Self.weekdays[i]))
                }
            }
            Text("有作答就算一天，一週 5 天達標；答對 \(dailyGoal) 題會打勾。")
                .appFont(12, relativeTo: .caption1)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func dayLabel(_ day: WeeklyGoal.Day, weekday: String) -> String {
        if day.isFuture { return "星期\(weekday)，還沒到" }
        if day.goalMet { return "星期\(weekday)，達到每日題數，答對 \(day.count) 題" }
        if day.studied { return "星期\(weekday)，有作答，答對 \(day.count) 題" }
        return "星期\(weekday)，沒有作答"
    }

    // MARK: Heatmap

    private func heatmapCard(_ s: StudyLogSummary) -> some View {
        let first = s.cells.first?.date ?? .now
        let lastPast = s.cells.last { $0.level != nil }?.date ?? .now
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("每日作答題數").appFont(15, .bold)
                Spacer()
                Text("\(DateText.monthDay.string(from: first)) – \(DateText.monthDay.string(from: lastPast))")
                    .appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Text("近 5 週共 \(s.heatmapTotal) 題，含模擬考").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            HStack(spacing: 5) {
                ForEach(Self.weekdays, id: \.self) { Text($0).frame(maxWidth: .infinity) }
            }
            .appFont(11, relativeTo: .caption2)
            .foregroundStyle(Palette.muted)
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(Array(s.cells.enumerated()), id: \.offset) { i, cell in
                    heatCell(cell, index: i)
                }
            }
            legend
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func heatCell(_ cell: StudyHeatmap.Cell, index: Int) -> some View {
        let cal = Calendar.current
        let dayNum = cal.component(.day, from: cell.date)
        let label = dayNum == 1 ? DateText.monthDay.string(from: cell.date) : "\(dayNum)"
        let isToday = cal.isDateInToday(cell.date)
        return ZStack {
            if let level = cell.level {
                RoundedRectangle(cornerRadius: 8).fill(HeatRamp.fills[level])
                    .opacity(grown ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(Double(index) * 0.01), value: grown)
                Text(label).foregroundStyle(HeatRamp.text(level))
            } else {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.chipBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text(label).foregroundStyle(Palette.muted)
            }
            if isToday {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ink, lineWidth: 2)
            }
        }
        .appFont(12, relativeTo: .caption1)
        .monospacedDigit()
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.level == nil ? "\(DateText.longMonthDay.string(from: cell.date))，還沒到"
                            : "\(DateText.longMonthDay.string(from: cell.date)) \(cell.count) 題")
    }

    private var legend: some View {
        let ranges = StudyHeatmap.ranges(goal: dailyGoal)
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Text("少").padding(.trailing, 2)
                ForEach(0..<HeatRamp.fills.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).fill(HeatRamp.fills[i])
                        .frame(width: 14, height: 14)
                }
                Text("多").padding(.leading, 2)
            }
            Text("由淺到深：" + ranges.joined(separator: "、") + " 題")
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .appFont(11, relativeTo: .caption2)
        .foregroundStyle(Palette.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("顏色由淺到深代表 " + ranges.joined(separator: "、") + " 題")
    }

    // MARK: Accuracy

    private func accuracyCard(_ a: AccuracySplit.Result) -> some View {
        AccuracySplitCard(result: a, grown: grown)
    }

    // MARK: Mistake digestion

    private func digestCard(_ d: MistakeDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("錯題消化").appFont(15, .bold)
                Spacer()
                Text("共收錄 \(d.total) 題").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            GeometryReader { geo in
                let share = d.total > 0 ? CGFloat(d.mastered) / CGFloat(d.total) : 0
                HStack(spacing: 2) {
                    if d.mastered > 0 {
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4,
                                               bottomTrailingRadius: d.reviewing == 0 ? 4 : 0, topTrailingRadius: d.reviewing == 0 ? 4 : 0)
                            .fill(Palette.chart)
                            .frame(width: max(4, (geo.size.width - 2) * share * (grown ? 1 : 0)))
                    }
                    UnevenRoundedRectangle(topLeadingRadius: d.mastered == 0 ? 4 : 0, bottomLeadingRadius: d.mastered == 0 ? 4 : 0,
                                           bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .fill(d.total == 0 ? Palette.segmentTrack : HeatRamp.fills[1])
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            HStack {
                legendDot(Palette.chart, "已熟練 \(d.mastered)")
                Spacer()
                legendDot(HeatRamp.fills[1], "複習中 \(d.reviewing)")
            }
            .appFont(13, relativeTo: .footnote)
            Text("複習得夠穩才算熟練；答錯或猜的會早點再練。")
                .appFont(12, relativeTo: .caption1)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .accessibilityElement(children: .combine)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(text).monospacedDigit()
        }
    }
}

/// 新題正確率 vs 複習題正確率 (last 30 days), shared by 學習紀錄 and 成績.
struct AccuracySplitCard: View {
    let result: AccuracySplit.Result
    var grown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("作答正確率").appFont(15, .bold)
                Spacer()
                Text("近 \(StudyLogSummary.accuracyDays) 天").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .top, spacing: 12) {
                column("新題正確率", result.new, color: Palette.chart)
                column("複習題正確率", result.review, color: HeatRamp.fills[2])
            }
            Text("新題是第一次做的題目，正確率比較接近考試的狀況；複習題做過，通常會比較高。")
                .appFont(12, relativeTo: .caption1)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func column(_ title: String, _ rate: AccuracySplit.Rate, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(rate.shownPercent.map(String.init) ?? "—").appFont(26, .bold, relativeTo: .title1).monospacedDigit()
                if rate.shownPercent != nil { Text("%").appFont(14).foregroundStyle(Palette.muted) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.segmentTrack)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(rate.shownPercent ?? 0) / 100 * (grown ? 1 : 0))
                }
            }
            .frame(height: 6)
            Text(rate.total > 0 ? "\(rate.correct) / \(rate.total) 題" : "還沒有資料")
                .appFont(12, relativeTo: .caption1).monospacedDigit().foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rate.shownPercent.map { "\(title) \($0)%，\(rate.correct) / \(rate.total) 題" } ?? "\(title)，還沒有資料")
    }
}
