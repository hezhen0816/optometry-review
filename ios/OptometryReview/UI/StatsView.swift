import SwiftUI
import SwiftData
import Charts

/// Derived numbers for 成績 and the Today trend card.
struct ScoreSummary {
    let entries: [ScoreHistory.Entry]
    let latest: [String: Int]
    let previous: [String: Int]
    let series: [ScoreHistory.Point]
    let projection: PassProjection.Result

    init(exams: [MockExam]) {
        entries = ScoreHistory.entries(from: exams)
        latest = ScoreHistory.latest(entries)
        previous = ScoreHistory.previous(entries)
        series = ScoreHistory.averageSeries(entries)
        projection = PassProjection.evaluate(latest: latest)
    }

    var isEmpty: Bool { entries.isEmpty }
    var average: Double? { series.last?.average }
    var takenCount: Int { latest.count }
    var missing: [String] { Subjects.all.filter { latest[$0] == nil } }

    /// Change of the average since the previous mock.
    var averageDelta: Double? {
        guard series.count >= 2 else { return nil }
        return series[series.count - 1].average - series[series.count - 2].average
    }

    /// Lowest latest score below the reference line.
    var focus: (subject: String, score: Int)? {
        Subjects.all.compactMap { s in latest[s].map { (s, $0) } }
            .filter { $0.1 < ExamRules.referenceLine }
            .min { $0.1 < $1.1 }
    }

    /// "五科平均" when all five are taken, otherwise "已考 3 科平均".
    var averageLabel: String { missing.isEmpty ? "五科平均" : "已考 \(takenCount) 科平均" }

    static func signed(_ v: Double) -> String {
        let s = String(format: "%.1f", abs(v))
        return v > 0.05 ? "+\(s)" : (v < -0.05 ? "−\(s)" : "±0")
    }
}

/// 成績 tab.
struct StatsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router
    @Query(filter: #Predicate<MockExam> { $0.finishedAt != nil }, sort: \MockExam.startedAt)
    private var exams: [MockExam]
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false

    @State private var accuracy: AccuracySplit.Result?
    @State private var customRequest: CustomPracticeRequest?
    @State private var showLog = false
    @State private var detailSubject: String?
    @State private var drawProgress: CGFloat = 0
    @State private var path = NavigationPath()
    @State private var pointStats: [PointStat] = []
    @State private var handoutRoute: HandoutRoute?
    @State private var showPoints = false
    /// The trend line draws only the first time it is shown in this app session.
    private static var didDrawTrend = false

    var body: some View {
        let summary = ScoreSummary(exams: exams)
        return NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("成績").headingFont(32)
                        Spacer()
                        Button { showLog = true } label: {
                            HStack(spacing: 4) {
                                Text("學習紀錄").appFont(15, .medium)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    LeaderboardEntryRow()
                    if summary.isEmpty {
                        emptyState
                        subjectRows(summary)
                    } else {
                        averageCard(summary)
                        subjectRows(summary)
                        projectionCard(summary)
                    }
                    if !pointStats.isEmpty {
                        StatsPointsCard(stats: pointStats) {
                            handoutRoute = HandoutRoute(unitID: $0.point.unitID, pointID: $0.point.id)
                        } onAll: { showPoints = true }
                    }
                    if let accuracy, accuracy.new.total + accuracy.review.total > 0 {
                        AccuracySplitCard(result: accuracy)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .readableScrollWidth()
            .foregroundStyle(Palette.ink)
            .background(Palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .trackScreen("stats")
            .interactivePopEnabled()
            .navigationDestination(isPresented: $showLog) { StudyLogView(backLabel: "返回成績") }
            .navigationDestination(item: $detailSubject) { SubjectDetailView(subject: $0) }
            .navigationDestination(item: $handoutRoute) { HandoutView(route: $0, backLabel: "返回成績") }
            .navigationDestination(isPresented: $showPoints) { AllPointsView(backLabel: "返回成績") }
            .navigationDestination(for: LeaderboardRoute.self) { route in
                switch route {
                case .board: LeaderboardView()
                case .member(let entry): LeaderboardMemberView(entry: entry)
                case .settings: SettingsView(backLabel: "返回讀書夥伴").trackScreen("settings")
                }
            }
            .customPractice($customRequest)
            .onChange(of: router.rootRequest(AppRouter.Tab.stats)) {
                path = NavigationPath()
                showLog = false
                detailSubject = nil
                handoutRoute = nil
                showPoints = false
            }
            .onAppear {
                let since = Calendar.current.date(byAdding: .day, value: -StudyLogSummary.accuracyDays,
                                                  to: Calendar.current.startOfDay(for: .now))!
                accuracy = AccuracySplit.compute(StudyStore(context: context).attemptFacts(), since: since)
                let scope = PointStatsLoader.dailyQuestions(bank: bank, includeSpecial: includeSpecial)
                pointStats = PointStatsLoader.ordered(PointStatsLoader.load(context: context, bank: bank, questions: scope), bank: bank)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(Palette.accent)
            Text("做完第一份模擬考就會出現走勢").appFont(17, .bold)
            Text("每份單科模擬考交卷後，這裡會列出各科分數、五科平均和及格推估。")
                .appFont(14, relativeTo: .subheadline)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
            let uncounted = exams.filter { !$0.countsTowardScores }.count
            if uncounted > 0 {
                Text("已交的 \(uncounted) 份沒有計入：作答未滿 \(ExamRules.questionCount * 4 / 5) 題或錯題加強卷不計入成績。")
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("去模擬考") { router.tab = AppRouter.Tab.exam }
                .buttonStyle(PrimaryButtonStyle(height: 50))
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    // MARK: Average + trend

    private func averageCard(_ s: ScoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.averageLabel)（各科最近一次模擬考）")
                        .appFont(13, relativeTo: .footnote)
                        .foregroundStyle(Palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ScoreHistory.format(s.average ?? 0)).appFont(40, .bold, relativeTo: .largeTitle).monospacedDigit()
                        Text("分").appFont(15).foregroundStyle(Palette.muted)
                    }
                    verdictChip(s.projection)
                }
                Spacer(minLength: 8)
                if let d = s.averageDelta {
                    deltaPill(d)
                }
            }
            if s.series.count >= 2 {
                trendChart(s.series)
            } else {
                Text("再交一份模擬考，就會畫出平均走勢。")
                    .appFont(13, relativeTo: .footnote)
                    .foregroundStyle(Palette.muted)
                    .padding(.vertical, 6)
            }
            if !s.missing.isEmpty {
                Text("平均只算已考的科目；還沒考：\(s.missing.joined(separator: "、"))")
                    .appFont(12, relativeTo: .caption1)
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.card))
    }

    /// Pass verdict next to the average, so a high average with a 0-score subject is not read as passing.
    private func verdictChip(_ p: PassProjection.Result) -> some View {
        let (icon, fg, bg): (String, Color, Color) = {
            switch p {
            case .pass: return ("checkmark.circle.fill", Palette.accent, Palette.accentSoft)
            case .fail: return ("exclamationmark.circle.fill", Palette.warn, Palette.warnSoft)
            case .missing: return ("hourglass", Palette.muted, Palette.badge)
            }
        }()
        return Label(p.headline, systemImage: icon)
            .appFont(13, .bold, relativeTo: .footnote)
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(bg))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deltaPill(_ d: Double) -> some View {
        HStack(spacing: 4) {
            if abs(d) >= 0.05 {
                Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(d > 0 ? Palette.chart : Palette.warn)
            }
            Text("比上次 \(ScoreSummary.signed(d))").appFont(13, .bold, relativeTo: .footnote).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Palette.accentSoft))
        .accessibilityElement(children: .combine)
    }

    private func trendChart(_ points: [ScoreHistory.Point]) -> some View {
        let values = points.map(\.average)
        let lo = max(0, (min(values.min() ?? 60, 60) - 6).rounded(.down))
        let hi = min(100, (max(values.max() ?? 60, 60) + 8).rounded(.up))
        return Chart {
            RuleMark(y: .value("參考線", 60))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("及格 60").appFont(11, relativeTo: .caption2).foregroundStyle(Palette.muted)
                }
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                LineMark(x: .value("次", i + 1), y: .value("平均", p.average))
                    .foregroundStyle(Palette.chart)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("次", i + 1), y: .value("平均", p.average))
                    .foregroundStyle(Palette.chart)
                    .symbolSize(i == points.count - 1 ? 60 : 28)
                    // Placed on the side away from the incoming segment so the label never sits on the line.
                    .annotation(position: Self.lastLabelBelow(points) ? .bottom : .top, alignment: .trailing, spacing: 6) {
                        if i == points.count - 1 {
                            Text(ScoreHistory.format(p.average)).appFont(12, .bold, relativeTo: .caption1)
                        }
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: 0.7...(Double(points.count) + 0.3))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel().font(.system(size: 11))
            }
        }
        .frame(height: 130)
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: geo.size.width * drawProgress)
            }
        }
        .onAppear {
            let animate = !StatsView.didDrawTrend && !reduceMotion
            StatsView.didDrawTrend = true
            guard animate else { drawProgress = 1; return }
            drawProgress = 0
            withAnimation(.easeInOut(duration: 0.6)) { drawProgress = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel(trendDescription(points))
        .overlay(alignment: .bottom) {
            // Date labels drawn outside Charts so the last one is never dropped at the plot edge.
            HStack {
                Text(DateText.monthDay.string(from: points.first!.date))
                Spacer()
                Text("最近 \(DateText.monthDay.string(from: points.last!.date))")
            }
            .appFont(11, relativeTo: .caption2)
            .foregroundStyle(Palette.muted)
            .padding(.leading, 28)
            .offset(y: 16)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 16)
    }

    /// The last segment falls: its label goes under the point (the line comes from above-left).
    static func lastLabelBelow(_ points: [ScoreHistory.Point]) -> Bool {
        guard points.count >= 2 else { return false }
        return points[points.count - 1].average < points[points.count - 2].average
    }

    private func trendDescription(_ points: [ScoreHistory.Point]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        return "平均走勢：第一次 \(ScoreHistory.format(first.average)) 分，最近 \(ScoreHistory.format(last.average)) 分，共 \(points.count) 次模擬考"
    }

    // MARK: Subjects

    private func subjectRows(_ s: ScoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.isEmpty ? "單科分析" : "各科分數 ・ 比上次").appFont(15, .bold).foregroundStyle(Palette.muted)
                Spacer()
                Text("直線為 60 分").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            VStack(spacing: 0) {
                ForEach(Array(Subjects.all.enumerated()), id: \.offset) { i, name in
                    subjectRow(name, s, isFocus: s.focus?.subject == name)
                    if i < Subjects.all.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
    }

    private func subjectRow(_ name: String, _ s: ScoreSummary, isFocus: Bool) -> some View {
        let score = s.latest[name]
        let prev = s.previous[name]
        let low = (score ?? 100) < ExamRules.referenceLine
        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(name).appFont(15, isFocus ? .bold : .regular)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFocus {
                    Button {
                        Haptics.selection()
                        practiceFocus(name)
                    } label: {
                        HStack(spacing: 3) {
                            Text("最值得補")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .heavy))
                        }
                        .appFont(11, .bold, relativeTo: .caption2)
                        .padding(.leading, 8).padding(.trailing, 7).padding(.vertical, 2)
                        .foregroundStyle(Palette.warn)
                        .background(Capsule().fill(Palette.warnSoft))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -12)
                }
                if let score, let prev {
                    let d = score - prev
                    HStack(spacing: 2) {
                        if d != 0 {
                            Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(d > 0 ? Palette.chart : Palette.warn)
                        }
                        Text(d > 0 ? "+\(d)" : (d < 0 ? "−\(-d)" : "±0")).appFont(13, relativeTo: .footnote).monospacedDigit()
                    }
                    .frame(minWidth: 40, alignment: .trailing)
                }
                Text(score.map(String.init) ?? "還沒考")
                    .appFont(score == nil ? 13 : 17, score == nil ? .regular : .bold)
                    .monospacedDigit()
                    .foregroundStyle(score == nil ? Palette.muted : Palette.ink)
                    .frame(minWidth: 30, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.trailing, -2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.segmentTrack)
                    Capsule().fill(low ? Palette.warn : Palette.chart)
                        .frame(width: geo.size.width * CGFloat(score ?? 0) / 100)
                    Rectangle().fill(Palette.ink).frame(width: 2, height: 12)
                        .offset(x: geo.size.width * 0.6 - 1)
                }
            }
            .frame(height: 6)
            .padding(.trailing, 20)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            detailSubject = name
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel(name, score: score, prev: prev, focus: isFocus))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("開啟單科分析")
        .accessibilityAction { detailSubject = name }
        .accessibilityActions {
            if isFocus { Button("練這科") { practiceFocus(name) } }
        }
    }

    /// 自選練習 of the subject: its 未熟練錯題, or unseen questions when it has none.
    private func practiceFocus(_ subject: String) {
        let open = StudyStore(context: context).openMistakeIDs(subject: subject, bank: bank, includeSpecial: includeSpecial)
        customRequest = .shortcut(subject: subject, kind: open.isEmpty ? .unseen : .missed)
    }

    private func rowLabel(_ name: String, score: Int?, prev: Int?, focus: Bool) -> String {
        guard let score else { return "\(name)，還沒考" }
        var t = "\(name) \(score) 分"
        if let prev { t += "，上次 \(prev) 分" }
        if focus { t += "，最值得補" }
        return t
    }

    // MARK: Projection

    private func projectionCard(_ s: ScoreSummary) -> some View {
        var isMissing = false
        if case .missing = s.projection { isMissing = true }
        let (icon, title, detail, good): (String, String, String, Bool) = {
            switch s.projection {
            case .pass(let avg):
                return ("checkmark.circle", "照目前推估：及格",
                        "平均 \(ScoreHistory.format(avg)) ≥ 60，且沒有 0 分的科目", true)
            case .fail(let avg, let zeros):
                let why = zeros.isEmpty ? "平均 \(ScoreHistory.format(avg)) 低於 60"
                    : "\(zeros.joined(separator: "、")) 0 分；任一科 0 分就不及格"
                return ("exclamationmark.circle", "照目前推估：未達", why, false)
            case .missing(let subjects):
                return ("hourglass", "還不能推估及格",
                        "還沒考：\(subjects.joined(separator: "、"))。五科都至少考一次才推估。", false)
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(good ? Palette.accent : (isMissing ? Palette.muted : Palette.warn))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(15, .bold)
                Text(detail).appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(good ? Palette.accentSoft : (isMissing ? Palette.badge : Palette.warnSoft)))
        .accessibilityElement(children: .combine)
    }
}

/// Small trend card on 今日 linking to 成績.
struct TrendCard: View {
    let summary: ScoreSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(summary.averageLabel) \(ScoreHistory.format(summary.average ?? 0)) 分")
                        .appFont(13, relativeTo: .footnote)
                        .foregroundStyle(Palette.muted)
                    if let d = summary.averageDelta {
                        HStack(spacing: 4) {
                            if abs(d) >= 0.05 {
                                Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(d > 0 ? Palette.chart : Palette.warn)
                            }
                            Text("比上次 \(ScoreSummary.signed(d))").appFont(15, .bold).monospacedDigit()
                        }
                    } else {
                        Text("再交一份就看得到走勢").appFont(15, .bold)
                    }
                    if let f = summary.focus {
                        Text("最值得補：\(f.subject) \(f.score) 分")
                            .appFont(12, .bold, relativeTo: .caption1)
                            .foregroundStyle(Palette.warn)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if summary.series.count >= 2 {
                    Sparkline(values: summary.series.map(\.average))
                        .frame(width: 110, height: 44)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("開啟成績")
    }
}

/// Tiny line with the 60-point reference, last point emphasised.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let lo = min(values.min() ?? 60, 60) - 5
            let hi = max(values.max() ?? 60, 60) + 5
            let w = geo.size.width - 8, h = geo.size.height - 8
            let pts = values.enumerated().map { i, v in
                CGPoint(x: 4 + w * CGFloat(i) / CGFloat(max(1, values.count - 1)),
                        y: 4 + h * CGFloat(1 - (v - lo) / (hi - lo)))
            }
            let refY = 4 + h * CGFloat(1 - (60 - lo) / (hi - lo))
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: refY))
                    p.addLine(to: CGPoint(x: geo.size.width, y: refY))
                }
                .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for q in pts.dropFirst() { p.addLine(to: q) }
                }
                .stroke(Palette.chart, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(Palette.chart)
                        .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(last)
                }
            }
        }
    }
}
