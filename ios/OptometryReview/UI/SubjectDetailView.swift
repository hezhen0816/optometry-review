import SwiftUI
import SwiftData
import Charts

/// 單科分析, pushed from a subject row on 成績.
struct SubjectDetailView: View {
    let subject: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @Query(filter: #Predicate<MockExam> { $0.finishedAt != nil }, sort: \MockExam.startedAt)
    private var exams: [MockExam]

    @State private var report: SubjectAnalysis.Report?
    @State private var session: SessionRequest?
    @State private var customRequest: CustomPracticeRequest?
    @State private var unitRoute: UnitRoute?
    @AppStorage(YearFilterStore.key(.subjectDetail)) private var yearsRaw = ""
    @State private var showYears = false

    private var years: YearSelection { YearFilterStore.decode(yearsRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let r = report {
                    header(r)
                    if !r.trend.isEmpty { trendCard(r) }
                    accuracyCard(r)
                    weakUnitCard(r)
                    reasonCard(r)
                    yearCard(r)
                    statusCard(r)
                    if let seconds = r.averageSeconds { paceCard(seconds) }
                    frequentSection(r)
                    Button(r.openMistakeIDs.isEmpty ? "練這科的錯題" : "練這科的錯題 · \(r.openMistakeIDs.count) 題") {
                        practiceMistakes()
                    }
                        .buttonStyle(PrimaryButtonStyle(height: 52))
                        .disabled(r.openMistakeIDs.isEmpty)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .readableScrollWidth()
        // Pinned so the way back stays visible while scrolling.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton(label: "返回成績") { dismiss() }
                Spacer()
                YearFilterButton(active: years.mode != .all) { showYears = true }
                    .padding(.trailing, 20)
            }
            .padding(.leading, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .background(Palette.ground.ignoresSafeArea(edges: .top))
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("subjectDetail")
        .onAppear(perform: load)
        .onChange(of: yearsRaw) { load() }
        .sheet(isPresented: $showYears) {
            YearFilterSheet(initial: years,
                            count: { sel in
                                StudyStore(context: context).subjectPool(subject, bank: bank, includeSpecial: includeSpecial)
                                    .filter { sel.contains($0.year) }.count
                            },
                            note: "題目統計只算範圍內的題目；模擬考分數不受影響。") { sel in
                YearFilterStore.set(sel, for: .subjectDetail)
            }
        }
        .fullScreenCover(item: $session, onDismiss: load) { req in
            ReviewSessionView(request: req)
        }
        .customPractice($customRequest, onFinish: load)
        .navigationDestination(item: $unitRoute) { UnitDetailView(unitID: $0.unitID, backTitle: subject) }
    }

    private func load() {
        report = StudyStore(context: context).subjectReport(subject: subject, bank: bank, includeSpecial: includeSpecial,
                                                            years: years)
    }

    /// 自選練習 prefilled with this subject's 未熟練錯題 (待複習 + 學習中).
    private func practiceMistakes() {
        Haptics.selection()
        var request = CustomPracticeRequest.shortcut(subject: subject, kind: .missed)
        var choice = request.choice
        choice.scope.years = years
        request = CustomPracticeRequest(choice: choice)
        customRequest = request
    }

    // MARK: Header

    private func header(_ r: SubjectAnalysis.Report) -> some View {
        let isFocus = ScoreSummary(exams: exams).focus?.subject == subject
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(subject).headingFont(30)
                    .lineLimit(2).minimumScaleFactor(0.7)
                if isFocus {
                    Text("最值得補").appFont(12, .bold, relativeTo: .caption1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .foregroundStyle(Palette.warn)
                        .background(Capsule().fill(Palette.warnSoft))
                        .fixedSize()
                }
            }
            if let label = years.label {
                YearRangeChip(label: label) { YearFilterStore.set(.all, for: .subjectDetail) }
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    // Uncounted mocks never set the score shown here, so say which one it is when there are any.
                    Text(r.trend.contains { !$0.counted } ? "最近一次計分模擬考" : "最近一次模擬考")
                        .appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                    if let latest = r.latest {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(latest)").appFont(40, .bold, relativeTo: .largeTitle).monospacedDigit()
                                .foregroundStyle(latest < ExamRules.referenceLine ? Palette.warn : Palette.ink)
                            Text("分").appFont(15).foregroundStyle(Palette.muted)
                        }
                    } else {
                        // Finished mocks that were not scored (too few answers, 錯題加強) say so instead of 還沒考.
                        Text(r.trend.isEmpty ? "還沒考" : "未計分").appFont(20, .bold).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 8)
                if let d = r.delta { deltaPill(d) }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.bottom, 4)
    }

    private func deltaPill(_ d: Int) -> some View {
        HStack(spacing: 4) {
            if d != 0 {
                Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(d > 0 ? Palette.chart : Palette.warn)
            }
            Text("比上次 \(d > 0 ? "+\(d)" : (d < 0 ? "−\(-d)" : "±0"))").appFont(13, .bold, relativeTo: .footnote).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Palette.accentSoft))
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).appFont(15, .bold)
                Spacer()
                if let note { Text(note).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted) }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).appFont(14, relativeTo: .subheadline).foregroundStyle(Palette.muted)
    }

    private func bar(_ fraction: Double, color: Color, height: CGFloat = 6) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(height > 6 ? Palette.badge : Palette.segmentTrack)
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }

    // MARK: Trend

    private func trendCard(_ r: SubjectAnalysis.Report) -> some View {
        let points = r.trend
        let hasUncounted = points.contains { !$0.counted }
        let uncounted = points.filter { !$0.counted }.count
        let note = uncounted == 0 ? "共 \(points.count) 次" : "計分 \(points.count - uncounted) 次・未計分 \(uncounted) 次"
        return card("模擬考分數走勢", note: note) {
            if points.count >= 2 {
                trendChart(points)
                if hasUncounted {
                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.chart).frame(width: 8, height: 8)
                            Text("計入成績")
                        }
                        HStack(spacing: 6) {
                            Circle().strokeBorder(Palette.chart, lineWidth: 2).frame(width: 9, height: 9)
                            Text("未計入成績")
                        }
                    }
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                }
            } else {
                emptyText("再考一次就有走勢")
            }
        }
    }

    private func trendChart(_ points: [SubjectAnalysis.ScorePoint]) -> some View {
        let values = points.map { Double($0.score) }
        let lo = max(0, (min(values.min() ?? 60, 60) - 8).rounded(.down))
        let hi = min(100, (max(values.max() ?? 60, 60) + 10).rounded(.up))
        let counted = points.enumerated().filter { $0.element.counted }
        let lastCounted = counted.last?.offset
        return Chart {
            RuleMark(y: .value("參考線", 60))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("及格 60").appFont(11, relativeTo: .caption2).foregroundStyle(Palette.muted)
                }
            ForEach(counted, id: \.offset) { i, p in
                LineMark(x: .value("次", i + 1), y: .value("分數", p.score), series: .value("計入", "counted"))
                    .foregroundStyle(Palette.chart)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                PointMark(x: .value("次", i + 1), y: .value("分數", p.score))
                    .symbol(p.counted ? AnyChartSymbolShape(.circle) : AnyChartSymbolShape(.circle.strokeBorder(lineWidth: 2)))
                    .symbolSize(i == lastCounted ? 60 : 32)
                    .foregroundStyle(Palette.chart)
                    .annotation(position: .top, alignment: .trailing, spacing: 4) {
                        if i == lastCounted {
                            Text("\(p.score)").appFont(12, .bold, relativeTo: .caption1)
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
        .accessibilityElement()
        .accessibilityLabel(trendDescription(points))
        .overlay(alignment: .bottom) {
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

    private func trendDescription(_ points: [SubjectAnalysis.ScorePoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let uncounted = points.filter { !$0.counted }.count
        var t = "\(subject)模擬考走勢：第一次 \(first.score) 分，最近 \(last.score) 分"
        if uncounted > 0 { t += "，其中 \(uncounted) 次未計入成績" }
        return t
    }

    // MARK: Accuracy

    private func accuracyCard(_ r: SubjectAnalysis.Report) -> some View {
        card("正確率", note: "近 \(StudyLogSummary.accuracyDays) 天") {
            if r.accuracy.new.total + r.accuracy.review.total == 0 {
                emptyText("近 \(StudyLogSummary.accuracyDays) 天還沒作答")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    rateColumn("新題", r.accuracy.new, color: Palette.chart)
                    rateColumn("複習題", r.accuracy.review, color: Palette.dynamic(0x6FAFC9, 0x3E8FAE))
                }
            }
        }
    }

    private func rateColumn(_ title: String, _ rate: AccuracySplit.Rate, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            if let p = rate.shownPercent {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(p)").appFont(26, .bold, relativeTo: .title1).monospacedDigit()
                    Text("%").appFont(14).foregroundStyle(Palette.muted)
                }
                bar(Double(p) / 100, color: color)
                Text("\(rate.correct) / \(rate.total) 題").appFont(12, relativeTo: .caption1).monospacedDigit()
                    .foregroundStyle(Palette.muted)
            } else {
                Text("—").appFont(26, .bold, relativeTo: .title1).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Weak units

    private func weakUnitCard(_ r: SubjectAnalysis.Report) -> some View {
        card("弱的單元", note: "答過 \(SubjectAnalysis.weakUnitMinAttempts) 題以上") {
            if r.weakUnits.isEmpty {
                emptyText("再多做幾題就能看出弱點")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(r.weakUnits.enumerated()), id: \.element.unit.id) { i, w in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                        weakUnitRow(w)
                    }
                }
                .padding(.top, -4)
                .padding(.bottom, -6)
            }
        }
    }

    /// Opens the unit page (單元頁).
    private func weakUnitRow(_ w: SubjectAnalysis.WeakUnit) -> some View {
        let percent = w.rate.percent ?? 0
        let weak = percent < 50
        return Button {
            Haptics.selection()
            unitRoute = UnitRoute(unitID: w.unit.id)
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(w.unit.name).appFont(14, .medium, relativeTo: .subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if w.fewQuestions {
                        Text("題目少").appFont(11, relativeTo: .caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(Palette.muted)
                            .background(Capsule().fill(Palette.badge))
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("正確率 \(percent)%").appFont(14, weak ? .bold : .regular, relativeTo: .subheadline)
                        .monospacedDigit()
                        .foregroundStyle(weak ? Palette.warn : Palette.ink)
                    Text("答 \(w.rate.total) 題").appFont(12, relativeTo: .caption1).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
                .fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看這個單元")
    }

    // MARK: Reasons

    private func reasonCard(_ r: SubjectAnalysis.Report) -> some View {
        let maxCount = max(1, r.reasons.map(\.count).max() ?? 1)
        let top = r.reasons.max { $0.count < $1.count }?.reason
        return card("錯因", note: "未熟練錯題的最後錯因") {
            if r.reasonTotal == 0 {
                emptyText("還沒標錯因")
            } else {
                VStack(spacing: 8) {
                    ForEach(r.reasons, id: \.reason) { item in
                        HStack(spacing: 10) {
                            Text(item.reason).appFont(14, relativeTo: .subheadline)
                                .frame(width: 64, alignment: .leading)
                            bar(Double(item.count) / Double(maxCount),
                                color: item.reason == top ? Palette.warn : Palette.chart, height: 10)
                            Text("\(item.count)").appFont(14, .bold, relativeTo: .subheadline).monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Years

    private func yearCard(_ r: SubjectAnalysis.Report) -> some View {
        card("各年份正確率", note: "最弱需答 \(SubjectAnalysis.yearMinAttempts) 題以上") {
            if !r.hasAnswers {
                emptyText("還沒作答")
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(r.years, id: \.year) { y in
                        let weak = r.weakest.contains(y.year)
                        VStack(spacing: 4) {
                            Text(y.percent.map(String.init) ?? "–")
                                .appFont(11, weak ? .bold : .regular, relativeTo: .caption2).monospacedDigit()
                                .foregroundStyle(weak ? Palette.warn : Palette.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(weak ? Palette.warn : Palette.dynamic(0x6FAFC9, 0x3E8FAE))
                                .frame(height: max(2, CGFloat(y.percent ?? 0) * 0.6))
                                .opacity(y.total > 0 ? 1 : 0)
                            Text("\(y.year)").appFont(11, relativeTo: .caption2).monospacedDigit()
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(y.percent.map { "\(y.year) 年 \($0)%" } ?? "\(y.year) 年 沒做過")
                    }
                }
                .frame(height: 96, alignment: .bottom)
                HStack(alignment: .firstTextBaseline) {
                    if r.weakest.isEmpty {
                        Text("最弱：–").appFont(12, relativeTo: .caption1)
                            .accessibilityLabel("最弱年份：資料還不夠")
                    } else {
                        (Text("最弱：") + Text(r.weakest.map(String.init).joined(separator: "、") + " 年").bold().foregroundColor(Palette.warn))
                            .appFont(12, relativeTo: .caption1)
                    }
                    Spacer()
                    Text("– 沒做過").appFont(11, relativeTo: .caption2)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Status and coverage

    private func statusCard(_ r: SubjectAnalysis.Report) -> some View {
        let s = r.status
        let learning = Palette.dynamic(0x6FAFC9, 0x3E8FAE)
        return card("錯題狀態", note: "答錯或猜過的 \(s.total) 題") {
            if s.total == 0 {
                emptyText("還沒有錯題")
            } else {
                GeometryReader { geo in
                    let parts: [(Int, Color)] = [(s.due, Palette.warn), (s.learning, learning), (s.mastered, Palette.accent)]
                        .filter { $0.0 > 0 }
                    let gap: CGFloat = 2
                    let width = geo.size.width - gap * CGFloat(max(0, parts.count - 1))
                    HStack(spacing: gap) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            Rectangle().fill(part.1)
                                .frame(width: width * CGFloat(part.0) / CGFloat(s.total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                HStack(alignment: .top, spacing: 8) {
                    statusCount("待複習", s.due, Palette.warn)
                    statusCount("學習中", s.learning, learning)
                    statusCount("熟練", s.mastered, Palette.accent)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("題庫覆蓋").appFont(14, relativeTo: .subheadline)
                    Spacer()
                    (Text("已做過 ").foregroundColor(Palette.muted) + Text("\(r.seen)").bold()
                        + Text(" / \(r.poolSize)").foregroundColor(Palette.muted))
                        .appFont(14, relativeTo: .subheadline).monospacedDigit()
                }
                bar(r.poolSize > 0 ? Double(r.seen) / Double(r.poolSize) : 0, color: Palette.chart)
            }
            .padding(.top, s.total > 0 ? 10 : 2)
            .overlay(alignment: .top) {
                if s.total > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func statusCount(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(title).appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
            }
            Text("\(n)").appFont(20, .bold, relativeTo: .title3).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Pace

    private func paceCard(_ seconds: Int) -> some View {
        let pace = SubjectAnalysis.examPaceSeconds
        let scale = Double(max(100, seconds, pace))
        return card("作答速度", note: "模擬考每題平均") {
            paceRow("你", seconds, color: seconds > pace ? Palette.warn : Palette.chart, scale: scale, mine: true)
            paceRow("國考配速", pace, color: Palette.dynamic(0x8A9693, 0x6B7774), scale: scale, mine: false)
        }
    }

    private func paceRow(_ label: String, _ seconds: Int, color: Color, scale: Double, mine: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).appFont(14, relativeTo: .subheadline)
                .foregroundStyle(mine ? Palette.ink : Palette.muted)
                .frame(width: 64, alignment: .leading)
            bar(Double(seconds) / scale, color: color, height: 10)
            Text("\(seconds) 秒").appFont(14, mine ? .bold : .regular, relativeTo: .subheadline).monospacedDigit()
                .foregroundStyle(mine ? Palette.ink : Palette.muted)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Frequent mistakes

    private func frequentSection(_ r: SubjectAnalysis.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("常錯題").appFont(15, .bold).foregroundStyle(Palette.muted)
                Spacer()
                Text("錯 \(SubjectAnalysis.frequentWrongThreshold) 次以上").appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
            }
            let items = r.frequent.compactMap { f in bank.byID[f.questionID].map { (f, $0) } }
            if items.isEmpty {
                emptyText("目前沒有")
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.0.questionID) { i, pair in
                        frequentRow(pair.0, pair.1)
                        if i < items.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    }
                }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            }
        }
        .padding(.top, 4)
    }

    private func frequentRow(_ f: SubjectAnalysis.FrequentWrong, _ q: Question) -> some View {
        Button {
            Haptics.selection()
            session = SessionRequest(queue: [q.id], doneBefore: 0, isDaily: false, isPractice: true)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(q.sourceLabel).foregroundStyle(Palette.muted)
                        Text("錯 \(f.wrongCount) 次").bold().foregroundStyle(Palette.warn)
                    }
                    .appFont(12, relativeTo: .caption1)
                    Text(q.stem).appFont(14, relativeTo: .subheadline)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("練習").appFont(14, .bold, relativeTo: .subheadline)
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 44)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("練習這題")
    }
}
