import SwiftUI
import SwiftData

/// 模擬考 tab: single-subject mock setup and the resume card for an unfinished exam.
struct ExamSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @Query(sort: \MockExam.startedAt, order: .reverse) private var exams: [MockExam]
    @Query(sort: \FullMock.startedAt, order: .reverse) private var fullMocks: [FullMock]
    /// Session picked by hand for the full mock; nil = default.
    @State private var pickedFullCode: String?

    @State private var subject = Subjects.all[1]
    @State private var mode = ExamMode.wholePaper.rawValue
    /// Paper picked by hand for 整份歷屆; nil = next untaken.
    @State private var pickedPaperID: String?
    @State private var askReplace = false
    @State private var askAbandonFull = false
    @State private var showHistory = false
    @State private var showSingle = false
    @State private var openPaper: Paper?

    private var finished: [MockExam] { exams.filter(\.isFinished) }
    private var unfinished: MockExam? { exams.first { !$0.isFinished && !$0.isFullMockPart } }
    private var unfinishedFull: FullMock? { fullMocks.first { !$0.isFinished } }

    private var generalSessions: [ExamSession] { PaperCatalog.sessions(bank.papers, kind: ExamKind.general) }

    /// Sessions done as a full mock, or with all five papers done as whole-paper mocks.
    private var fullyTakenCodes: Set<String> {
        var codes = Set(fullMocks.filter(\.isFinished).map(\.code))
        let taken = takenPaperIDs
        for session in generalSessions where session.papers.allSatisfy({ taken.contains($0.id) }) { codes.insert(session.code) }
        return codes
    }

    private var defaultFullSession: ExamSession? {
        FullMockRules.defaultSession(generalSessions, fullyTaken: fullyTakenCodes)
    }

    private var fullSession: ExamSession? {
        pickedFullCode.flatMap { code in generalSessions.first { $0.code == code } } ?? defaultFullSession
    }
    private var examMode: ExamMode { ExamMode(rawValue: mode) ?? .wholePaper }
    private var store: StudyStore { StudyStore(context: context) }

    private var takenPaperIDs: Set<String> {
        Set(finished.compactMap { e in
            guard e.mode == .wholePaper, let code = e.paperCode else { return nil }
            return Paper.makeID(code: code, subject: e.subject)
        })
    }

    /// 一般 papers of the subject, plus 特考 when included, newest first.
    private var subjectPapers: [Paper] {
        bank.papers
            .filter { $0.subject == subject && ($0.examKind == ExamKind.general || includeSpecial) }
            .sorted { ($0.examKind == ExamKind.general ? 1 : 0, $0.year, $0.code) > ($1.examKind == ExamKind.general ? 1 : 0, $1.year, $1.code) }
    }

    private var nextPaper: Paper? {
        ExamBuilder.nextUntakenPaper(bank.papers.filter { $0.subject == subject && $0.examKind == ExamKind.general },
                                     taken: takenPaperIDs)
    }

    private var selectedPaper: Paper? {
        pickedPaperID.flatMap { bank.paperByID[$0] } ?? nextPaper
    }

    private var openMistakes: Int {
        store.openMistakeIDs(subject: subject, bank: bank, includeSpecial: includeSpecial).count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if let full = unfinishedFull {
                            VStack(alignment: .trailing, spacing: 0) {
                                fullResumeCard(full)
                                Button("放棄這次連考") { askAbandonFull = true }
                                    .appFont(14, .medium)
                                    .foregroundStyle(Palette.warn)
                                    .padding(.horizontal, 4)
                                    .frame(minHeight: 44)
                                    .buttonStyle(.plain)
                                    // Attached here so the dialog anchors to this button.
                                    .onChange(of: askAbandonFull) { _, now in
                                        // Shown once: the flag is set when the dialog closes.
                                        if !now { SettingsKey.markTipShown(SettingsKey.noteAbandonShown) }
                                    }
                                    .confirmationDialog("放棄這次五科連考？", isPresented: $askAbandonFull,
                                                        titleVisibility: .visible) {
                                        Button("放棄連考", role: .destructive) { abandonFull() }
                                        Button("取消", role: .cancel) {}
                                    } message: {
                                        if SettingsKey.tipPending(SettingsKey.noteAbandonShown) {
                                            Text("已作答的科目不會計分，也不會收進錯題本。")
                                        }
                                    }
                            }
                        }
                        if let exam = unfinished { resumeCard(exam) }
                        if unfinishedFull == nil { fullMockCard }
                        singleRow
                        PaperSessionsView { openPaper = $0 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
                .readableScrollWidth()
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .trackScreen("examSetup")
            .firstVisitTip(key: SettingsKey.tipPapersShown, title: "歷屆試卷搬到這裡",
                           message: "原本在「試題」的原始試卷現在在模擬考分頁的「歷屆試卷」：依年份看整份原卷，或逐題練。")
            .interactivePopEnabled()
            .navigationDestination(isPresented: $showHistory) { ExamHistoryView() }
            .navigationDestination(isPresented: $showSingle) { singleScreen }
            .navigationDestination(item: $openPaper) { PaperView(paper: $0) }
            .onChange(of: router.rootRequest(AppRouter.Tab.exam)) {
                showHistory = false
                showSingle = false
                openPaper = nil
            }
            .onChange(of: subject) { pickedPaperID = nil }
            .confirmationDialog("有一份模擬考還沒交卷", isPresented: $askReplace, titleVisibility: .visible) {
                if let old = unfinished {
                    Button("繼續那一份（\(old.subject)）") { router.activeExam = old }
                    Button("放棄那一份，開始新的", role: .destructive) {
                        context.delete(old)
                        try? context.save()
                        start()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let old = unfinished { Text("\(old.title) \(old.subject)，已答 \(old.answeredCount) 題。") }
            }
        }
    }

    // MARK: Single-subject screen

    /// One row on the tab root: 單科模擬 opens the setup screen (subject, how to draw, paper, start).
    private var singleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.selection()
                showSingle = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("單科模擬").appFont(16, .bold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 60)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private var singleScreen: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(label: "返回模擬考") { showSingle = false }
                Spacer()
            }
            .padding(.leading, 10).padding(.vertical, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("單科模擬").headingFont(28)
                    subjectSection
                    modeSection
                    infoLine
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .readableScrollWidth()
            // The paper choice sits with the start button so it is never below the fold.
            VStack(spacing: 8) {
                if examMode == .wholePaper { paperPicker.transition(.opacity) }
                Button("開始單科模擬") { requestStart() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canStart)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .readableBarWidth()
            .background(Palette.ground)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .trackScreen("examSetupSingle")
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("模擬考").headingFont(32)
            Spacer()
            Button { showHistory = true } label: {
                HStack(spacing: 4) {
                    Text("考試紀錄").appFont(15, .medium)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func resumeCard(_ exam: MockExam) -> some View {
        Button { router.activeExam = exam } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("繼續作答").appFont(16, .bold)
                    Text("\(exam.subject) ・ \(exam.title)").appFont(13, relativeTo: .footnote).opacity(0.9)
                    Text("已答 \(exam.answeredCount) / \(exam.questionIDs.count) ・ 剩 \(ExamClock.format(ExamRules.durationSeconds - exam.elapsed))")
                        .appFont(13, relativeTo: .footnote).monospacedDigit().opacity(0.9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.heroFill))
        }
        .buttonStyle(.plain)
    }

    private func fullResumeCard(_ full: FullMock) -> some View {
        let done = StudyStore(context: context).subjectExams(of: full).filter(\.isSubmitted).count
        let n = min(done + 1, Subjects.all.count)
        return Button { router.activeFullMock = full } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("繼續五科連考：第 \(n) 科").appFont(16, .bold)
                    Text("進行中：\(full.displayLabel)，第 \(n) 科／共 5 科 ・ \(Subjects.all[n - 1])")
                        .appFont(13, relativeTo: .footnote).opacity(0.9)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.heroFill))
        }
        .buttonStyle(.plain)
    }

    private var fullMockCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("五科連考模擬").appFont(15, .bold).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 10) {
                Text("五科連考，考完才公布分數")
                    .appFont(13, relativeTo: .footnote)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Menu {
                        ForEach(generalSessions.filter { $0.papers.count == Subjects.all.count }) { session in
                            Button {
                                pickedFullCode = session.code
                            } label: {
                                Text(session.label + (fullyTakenCodes.contains(session.code) ? "（考過）" : ""))
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("五科連考用試卷").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                                Text(fullSession.map { "\($0.label) 一般" } ?? "沒有可用的試卷").appFont(15, .bold)
                                    .foregroundStyle(Palette.ink)
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("連考試卷：\(fullSession?.label ?? "無")，點兩下換一份")
                    Button("開始") { startFull() }
                        .appFont(15, .bold)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accent))
                        .disabled(fullSession == nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
    }

    /// Opens the overview of an unsaved full mock; it is saved only when its first subject starts.
    private func startFull() {
        guard let session = fullSession else { return }
        pickedFullCode = nil
        router.activeFullMock = FullMock(code: session.code, label: session.label, now: .now)
    }

    /// Deletes the unfinished full mock and its subject exams (nothing of it was recorded yet).
    private func abandonFull() {
        guard let full = unfinishedFull else { return }
        for exam in StudyStore(context: context).subjectExams(of: full) { context.delete(exam) }
        context.delete(full)
        try? context.save()
    }

    private var subjectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("單科模擬").appFont(15, .bold).foregroundStyle(Palette.muted)
            VStack(spacing: 2) {
                ForEach(Subjects.all, id: \.self) { s in
                    let on = s == subject
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) { subject = s }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(on ? Palette.accent : Palette.muted, lineWidth: on ? 6 : 2)
                                .frame(width: 20, height: 20)
                            Text(s).appFont(15, on ? .bold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(lastScoreText(s)).appFont(13, relativeTo: .footnote)
                                .monospacedDigit()
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Palette.accentSoft : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        }
    }

    private func lastScoreText(_ s: String) -> String {
        guard let last = finished.filter({ $0.subject == s }).max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) })
        else { return "還沒考過" }
        return "上次 \(last.score) 分\(last.countsTowardScores ? "" : "（未計入）")"
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出題方式").appFont(15, .bold).foregroundStyle(Palette.muted)
            SegmentPicker(options: ExamMode.allCases.map(\.rawValue), selection: $mode, height: 44)
            Text(modeHint)
                .appFont(13, relativeTo: .footnote)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeHint: String {
        switch examMode {
        case .wholePaper:
            return "整份歷屆卷，預設最新未考"
        case .random:
            return "隨機抽 50 題"
        case .mistakes:
            let n = openMistakes
            if n == 0 { return "這科目前沒有還沒熟練的錯題。先用整份歷屆或隨機混合找出要補的題目。" }
            let fill = max(0, ExamRules.questionCount - n)
            return "只出你錯過、還沒熟練的題目（這科 \(n) 題）" + (fill > 0 ? "，不足的 \(fill) 題從答錯過或沒做過的題目補。" : "，最多 50 題。")
        }
    }

    private var paperPicker: some View {
        Menu {
            ForEach(subjectPapers) { p in
                Button {
                    pickedPaperID = p.id
                } label: {
                    Text(paperMenuLabel(p))
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("單科模擬用試卷 ・ \(subject)").appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Text(selectedPaper.map(paperTitle) ?? "沒有可用的試卷").appFont(15, .bold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let p = selectedPaper, pickedPaperID == nil || p.id == nextPaper?.id {
                    Text(takenPaperIDs.contains(p.id) ? "都考過了，從最新一份" : "下一份未考")
                        .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                }
                Text("換一份").appFont(14, .medium).foregroundStyle(Palette.accent)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        }
        .accessibilityLabel("單科模擬用試卷：\(selectedPaper.map(paperTitle) ?? "無")，點兩下換一份")
    }

    private func paperTitle(_ p: Paper) -> String {
        let label = PaperCatalog.sessionLabel(for: p, in: bank.papers)
        if p.sessionNote != nil { return label }
        return "\(label) \(p.examKind)"
    }

    private func paperMenuLabel(_ p: Paper) -> String {
        let score = finished.filter { $0.mode == .wholePaper && $0.paperCode == p.code && $0.subject == p.subject }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }?.score
        return paperTitle(p) + (score.map { "（考過 \($0) 分）" } ?? "")
    }

    private var infoLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("50 題 ・ 60 分鐘 ・ 每題 2 分").appFont(13, relativeTo: .footnote)
            (Text("計算器：") + Text(calculatorText).bold())
                .appFont(13, relativeTo: .footnote)
        }
        .lineSpacing(3)
    }

    private var calculatorText: String {
        if examMode == .wholePaper {
            guard let p = selectedPaper else { return "—" }
            return p.calculatorAllowed ? "可使用（\(paperTitle(p))試卷註記）" : "禁止使用（\(paperTitle(p))試卷註記）"
        }
        return "依每題原試卷，題目上會標示"
    }

    private var canStart: Bool {
        switch examMode {
        case .wholePaper: return selectedPaper != nil
        case .random: return !bank.questions.isEmpty
        case .mistakes: return openMistakes > 0
        }
    }

    // MARK: Actions

    private func requestStart() {
        if unfinished != nil { askReplace = true } else { start() }
    }

    private func start() {
        if let exam = store.makeExam(subject: subject, mode: examMode, paper: selectedPaper, bank: bank,
                                     includeSpecial: includeSpecial) {
            pickedPaperID = nil
            showSingle = false
            router.activeExam = exam
        }
    }
}

/// 考試紀錄: sessions × five subjects. Scores open their result, 「—」 opens the original paper,
/// full-mock rows open the full result; other mocks (random, mistakes) are listed below.
struct ExamHistoryView: View {
    /// Back button label; pushed from 模擬考 or 成績.
    var backLabel = "返回模擬考"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @Query(sort: \MockExam.startedAt, order: .reverse) private var exams: [MockExam]
    @Query(sort: \FullMock.startedAt, order: .reverse) private var fullMocks: [FullMock]

    private static let labelWidth: CGFloat = 92

    private var finished: [MockExam] { exams.filter(\.isFinished) }
    private var otherMocks: [MockExam] { finished.filter { $0.mode != .wholePaper } }

    private func sessions(_ kind: String) -> [ExamSession] { PaperCatalog.sessions(bank.papers, kind: kind) }

    /// Latest finished whole-paper exam of a paper (single or full mock).
    private func latestExam(code: String, subject: String) -> MockExam? {
        finished.filter { $0.mode == .wholePaper && $0.paperCode == code && $0.subject == subject }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    private func inProgressFull(_ code: String) -> FullMock? { fullMocks.first { $0.code == code && !$0.isFinished } }
    private func finishedFull(_ code: String) -> FullMock? {
        fullMocks.filter { $0.code == code && $0.isFinished }.max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    private var takenCount: Int {
        sessions(ExamKind.general).reduce(0) { sum, session in
            sum + Subjects.all.filter { subject in
                finished.contains { $0.mode == .wholePaper && $0.paperCode == session.code && $0.subject == subject
                    && $0.countsTowardScores }
            }.count
        }
    }

    var body: some View {
        let general = sessions(ExamKind.general)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BackButton(label: backLabel) { dismiss() }
                    .padding(.leading, -10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("考試紀錄").headingFont(28)
                        InfoButton(title: "怎麼看這張表", text: legend)
                        Spacer(minLength: 0)
                    }
                    Text("一般考試 \(general.count) 場 × 5 科，已考完 \(takenCount) 科")
                        .appFont(13, relativeTo: .footnote)
                        .foregroundStyle(Palette.muted)
                }
                matrix(general)
                if includeSpecial {
                    Text("特考").appFont(15, .bold).foregroundStyle(Palette.muted).padding(.top, 6)
                    matrix(sessions(ExamKind.special))
                }
                if !otherMocks.isEmpty {
                    Text("隨機混合與錯題加強").appFont(15, .bold).foregroundStyle(Palette.muted).padding(.top, 6)
                    otherList
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
    }

    /// Some score shown in the matrix comes from an exam that does not count toward scores.
    private var hasUncountedCell: Bool {
        let kinds = includeSpecial ? [ExamKind.general, ExamKind.special] : [ExamKind.general]
        return kinds.flatMap { sessions($0) }.contains { session in
            Subjects.all.contains { latestExam(code: session.code, subject: $0).map { !$0.countsTowardScores } ?? false }
        }
    }

    private var legend: String {
        let names = Subjects.all.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " ・ ")
        let uncounted = hasUncountedCell ? "灰色虛線框的分數作答未滿 40 題，未計入成績；" : ""
        return "\(names)。「已交」是五科連考進行中、分數還沒公布的科目；\(uncounted)「—」可看原始試卷。"
    }

    private func matrix(_ sessions: [ExamSession]) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("場次").frame(width: Self.labelWidth, alignment: .leading).padding(.leading, 4)
                ForEach(1...5, id: \.self) { Text("\($0)").frame(maxWidth: .infinity) }
            }
            .appFont(12, relativeTo: .caption1)
            .foregroundStyle(Palette.muted)
            .accessibilityHidden(true)
            ForEach(sessions) { session in
                HStack(spacing: 4) {
                    rowLabel(session)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(Subjects.all, id: \.self) { subject in
                        cell(session, subject: subject)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    @ViewBuilder
    private func rowLabel(_ session: ExamSession) -> some View {
        let parts = session.label.split(separator: " ", maxSplits: 2).map(String.init)
        let title = parts.prefix(2).joined(separator: " ")
        let note = parts.count > 2 ? parts[2] : ""
        if let full = inProgressFull(session.code) {
            Button { router.activeFullMock = full } label: {
                labelStack(title, sub: "連考・繼續", link: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.label)，五科連考進行中，點兩下繼續")
        } else if let full = finishedFull(session.code) {
            let j = FullMockJudgment(scores: StudyStore(context: context).subjectExams(of: full).map(\.score))
            NavigationLink {
                FullMockResultView(full: full, context: .history)
            } label: {
                labelStack(title, sub: "連考 \(ScoreHistory.format(j.average)) \(j.passed ? "及格" : "未達")", link: true,
                           warn: !j.passed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.label)，五科連考平均 \(ScoreHistory.format(j.average)) 分，\(j.passed ? "及格" : "未達")")
        } else {
            labelStack(title, sub: note, link: false)
        }
    }

    private func labelStack(_ title: String, sub: String, link: Bool, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).appFont(14, link ? .bold : .regular, relativeTo: .subheadline)
            if !sub.isEmpty {
                Text(sub).appFont(11, link ? .bold : .regular, relativeTo: .caption2)
                    .foregroundStyle(link ? (warn ? Palette.warn : Palette.accent) : Palette.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ session: ExamSession, subject: String) -> some View {
        let name = "\(session.label) \(subject)"
        if let full = inProgressFull(session.code),
           StudyStore(context: context).subjectExams(of: full).contains(where: { $0.subject == subject && $0.isSubmitted }) {
            Button { router.activeFullMock = full } label: {
                cellBox("已交", fill: Palette.badge, fg: Palette.ink, dashed: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) 已作答，五科考完後公布")
        } else if let exam = latestExam(code: session.code, subject: subject) {
            let low = exam.score < ExamRules.referenceLine
            let counted = exam.countsTowardScores
            NavigationLink {
                ExamResultView(exam: exam, context: .history)
            } label: {
                if counted {
                    cellBox("\(exam.score)", fill: low ? Palette.warnSoft : Palette.accentSoft, fg: low ? Palette.warn : Palette.ink, bold: true)
                } else {
                    cellBox("\(exam.score)", fill: Palette.badge, fg: Palette.muted, bold: true, dashed: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) \(exam.score) 分\(counted ? "" : "，未計入成績")")
        } else if let paper = session.papers.first(where: { $0.subject == subject }) {
            NavigationLink {
                PaperView(paper: paper)
            } label: {
                cellBox("—", fill: Palette.card, fg: Palette.muted, border: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) 未考，看原始試卷")
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func cellBox(_ text: String, fill: Color, fg: Color, bold: Bool = false, border: Bool = false,
                         dashed: Bool = false) -> some View {
        Text(text)
            .appFont(14, bold ? .bold : .regular, relativeTo: .subheadline)
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dashed ? Palette.muted : Palette.hairline,
                              style: StrokeStyle(lineWidth: border || dashed ? 1 : 0, dash: dashed ? [3, 2] : [])))
            .contentShape(Rectangle())
    }

    private var otherList: some View {
        VStack(spacing: 0) {
            ForEach(Array(otherMocks.enumerated()), id: \.element.examID) { i, exam in
                NavigationLink {
                    ExamResultView(exam: exam, context: .history)
                } label: {
                    row(exam)
                }
                .buttonStyle(.plain)
                if i < otherMocks.count - 1 {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }

    private func row(_ exam: MockExam) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(exam.subject).appFont(15, .bold)
                    if !exam.countsTowardScores { UncountedTag() }
                }
                Text("\(DateText.fullDate.string(from: exam.finishedAt ?? exam.startedAt)) ・ \(exam.title)")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(exam.score)").appFont(20, .bold).monospacedDigit()
                .foregroundStyle(exam.score >= ExamRules.referenceLine ? Palette.ink : Palette.warn)
            Text("分").appFont(13).foregroundStyle(Palette.muted)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
