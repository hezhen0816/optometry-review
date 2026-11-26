import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Pushed from 今日 or from 讀書夥伴.
    var backLabel = "返回今日"
    /// Opens with the 考試日期 picker expanded (今日 「設定考試日期」).
    var startEditingDate = false
    @State private var startEditingDateUsed = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.includeSpecial) private var includeSpecial = false
    @AppStorage(SettingsKey.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKey.reminderMinutes) private var reminderMinutes = SettingsKey.defaultReminderMinutes
    @AppStorage(SettingsKey.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(SettingsKey.detailHidesAnswer) private var detailHidesAnswer = false
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @AppStorage(LeaderboardModel.joinedKey) private var leaderboardJoined = false
    @AppStorage(LeaderboardModel.pendingLeaveKey) private var leavePending = false
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @Environment(\.openURL) private var openURL

    @State private var editingDate = false
    @State private var editingReminder = false
    @State private var reminderDenied = false
    @State private var exportFailed = false
    @State private var showHelp = false
    @State private var tipsReset = false
    @State private var showRules = false
    @State private var nameDraft = ""
    @State private var leaderboardBusy = false
    @State private var leaderboardError: LeaderboardError?
    @State private var showImporter = false
    @State private var importPreview: StudyImport.Preview?
    @State private var importMessage: ImportMessage?
    @State private var sync = CloudSync.shared
    @FocusState private var nameFocused: Bool
    private let leaderboard = LeaderboardModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BackButton(label: backLabel) { dismiss() }
                    .padding(.leading, -10)
                Text("設定").headingFont(30)

                section("讀書計畫") {
                    row(divider: true) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { editingDate.toggle() }
                        } label: {
                            HStack {
                                Text("考試日期").appFont(15)
                                Spacer()
                                Text(examDate > 0 ? DateText.fullDate.string(from: Date(timeIntervalSince1970: examDate)) : "未設定")
                                    .appFont(15)
                                    .foregroundStyle(Palette.accent)
                                Image(systemName: editingDate ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if editingDate {
                        VStack(spacing: 4) {
                            DatePicker("考試日期", selection: dateBinding, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                            if examDate > 0 {
                                Button("清除考試日期") { examDate = 0 }
                                    .appFont(14)
                                    .foregroundStyle(Palette.warn)
                                    .frame(minHeight: 44)
                            }
                        }
                        .transition(.opacity)
                        Divider().overlay(Palette.hairline)
                    }
                    row(divider: true) {
                        Stepper(value: $dailyGoal, in: SettingsKey.dailyGoalRange, step: SettingsKey.dailyGoalStep) {
                            HStack {
                                Text("每日題數").appFont(15)
                                Spacer()
                                Text("\(dailyGoal) 題").appFont(15).monospacedDigit().foregroundStyle(Palette.accent)
                            }
                        }
                        .accessibilityValue("\(dailyGoal) 題")
                    }
                    reminderRow
                    if editingReminder && reminderEnabled {
                        DatePicker("提醒時間", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }

                section("題庫範圍") {
                    Toggle(isOn: $includeSpecial) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("納入特考試題").appFont(15)
                            Text("特考是給已執業者的考試，難度可能和一般考試不同")
                                .appFont(12, relativeTo: .caption1)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(Palette.accent)
                    .padding(.vertical, 10)
                }

                section("操作") {
                    row(divider: true) {
                        Toggle(isOn: $hapticsEnabled) {
                            Text("震動回饋").appFont(15)
                        }
                        .tint(Palette.accent)
                        .padding(.vertical, 10)
                    }
                    Toggle(isOn: $detailHidesAnswer) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("題目頁預設遮住答案").appFont(15)
                            Text("從清單點開題目時，做過的題也先遮住")
                                .appFont(12, relativeTo: .caption1)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(Palette.accent)
                    .padding(.vertical, 10)
                }

                leaderboardSection

                section("資料") {
                    row(divider: true) { syncRow }
                    row(divider: true) {
                        Button(action: export) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("匯出作答紀錄").appFont(15).foregroundStyle(Palette.accent)
                                    Text("JSON 檔，可存到「檔案」或傳到電腦")
                                        .appFont(12, relativeTo: .caption1)
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if replacedExport != nil {
                        row(divider: true) { restoreRow }
                    }
                    row(divider: true) {
                        Button { showImporter = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("匯入作答紀錄").appFont(15).foregroundStyle(Palette.accent)
                                    Text("從匯出的 JSON 檔加回來；已有的資料不會被刪除或覆蓋")
                                        .appFont(12, relativeTo: .caption1)
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle(isOn: Binding(get: { usageEnabled }, set: setUsage)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用紀錄回傳").appFont(15)
                            Text(UsageDisclosure.short)
                                .appFont(12, relativeTo: .caption1)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(Palette.accent)
                    .padding(.vertical, 10)
                }

                section("說明") {
                    row(divider: true) {
                        Button { showHelp = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("使用說明").appFont(15).foregroundStyle(Palette.accent)
                                    Text("每個功能怎麼用，也可以重看導覽")
                                        .appFont(12, relativeTo: .caption1).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    row(divider: true) {
                        Button { showRules = true } label: {
                            HStack {
                                Text("複習怎麼排").appFont(15).foregroundStyle(Palette.accent)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    row(divider: false) {
                        Button {
                            for key in SettingsKey.allTips { UserDefaults.standard.set(false, forKey: key) }
                            withAnimation { tipsReset = true }
                        } label: {
                            HStack {
                                Text("重新顯示提示").appFont(15).foregroundStyle(Palette.accent)
                                Spacer()
                                if tipsReset {
                                    Text("已重設").appFont(13, relativeTo: .footnote).foregroundStyle(Palette.muted)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                footnote("題目與答案來自考選部考畢試題查詢平臺；有更正答案時以更正答案為準。")
                Text("版本 \(Self.versionText)")
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .readableScrollWidth()
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("通知權限未開啟，請到 iOS 設定開啟。", isPresented: $reminderDenied) {
            Button("打開設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("匯出失敗，請稍後再試", isPresented: $exportFailed) {
            Button("好", role: .cancel) {}
        }
        .alert(leaderboardError?.message ?? "", isPresented: Binding(get: { leaderboardError != nil },
                                                                     set: { if !$0 { leaderboardError = nil } })) {
            Button("好", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { readImport($0) }
        .alert("匯入這個檔案？", isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } }),
               presenting: importPreview) { preview in
            Button("匯入") { applyImport(preview) }
            Button("取消", role: .cancel) {}
        } message: { preview in
            Text("會加入 \(preview.summary.text)。已有的資料不會被刪除；同一則筆記以較新的為準，排程會依全部作答重新計算。")
        }
        .alert(importMessage?.title ?? "", isPresented: Binding(get: { importMessage != nil },
                                                                set: { if !$0 { importMessage = nil } }),
               presenting: importMessage) { _ in
            Button("好", role: .cancel) {}
        } message: { Text($0.body) }
        .navigationDestination(isPresented: $showRules) { ReviewRulesView() }
        .navigationDestination(isPresented: $showHelp) { HelpView() }
        .onAppear {
            if nameDraft.isEmpty { nameDraft = leaderboard.savedName }
            // Consumed once: returning from 規則／說明 must not re-expand the picker.
            if startEditingDate, !startEditingDateUsed {
                startEditingDateUsed = true
                editingDate = true
            }
        }
        .task { await leaderboard.retryPendingLeave() }
    }

    // MARK: Leaderboard

    private var leaderboardActive: Bool { usageEnabled && leaderboardJoined }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("讀書夥伴") {
                row(divider: true) {
                    HStack {
                        Text("參加讀書夥伴").appFont(15)
                            .foregroundStyle(usageEnabled ? Palette.ink : Palette.muted)
                        Spacer()
                        if leaderboardBusy { ProgressView().padding(.trailing, 6) }
                        Toggle("參加讀書夥伴", isOn: Binding(get: { leaderboardActive }, set: setJoined))
                            .labelsHidden()
                            .tint(Palette.accent)
                            .disabled(!usageEnabled || leaderboardBusy)
                    }
                }
                row(divider: false) {
                    HStack(spacing: 12) {
                        Text("顯示名稱").appFont(15)
                            .foregroundStyle(leaderboardActive ? Palette.ink : Palette.muted)
                        TextField("輸入名字", text: $nameDraft)
                            .appFont(15)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(leaderboardActive ? Palette.ink : Palette.muted)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                            .onChange(of: nameDraft) { _, v in
                                if v.count > LeaderboardText.maxNameLength {
                                    nameDraft = String(v.prefix(LeaderboardText.maxNameLength))
                                }
                            }
                            .onChange(of: nameFocused) { _, focused in if !focused { saveName() } }
                            .disabled(!leaderboardActive || leaderboardBusy)
                            .accessibilityLabel("顯示名稱")
                    }
                }
            }
            if leavePending {
                Text("退出讀書夥伴還沒送到伺服器，連上網路後會自動再試；在那之前其他人可能還看得到你。")
                    .appFont(12, relativeTo: .caption1)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.warn)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footnote(usageEnabled
                     ? "其他參加的人會看到你的顯示名稱、本週練了幾天（N／5）、本週答對題數，以及每天和各科的答對題數；看不到正確率、錯了哪些題、作答內容與模擬考分數。關掉就會從別人的畫面移除。"
                     : "需開啟下方「使用紀錄回傳」才能參加。")
        }
    }

    private func setJoined(_ on: Bool) {
        Haptics.selection()
        leaderboardBusy = true
        Task { @MainActor in
            defer { leaderboardBusy = false }
            do {
                if on { try await leaderboard.join(name: nameDraft.isEmpty ? leaderboard.name : nameDraft) }
                else { try await leaderboard.leave() }
            } catch let e as LeaderboardError {
                // A failed leave stays pending (shown under the section) and is retried; no alert needed.
                if on { leaderboardError = e }
            } catch {}
            nameDraft = leaderboard.name
        }
    }

    private func saveName() {
        guard leaderboardActive, !leaderboardBusy else { return }
        guard let name = LeaderboardText.validName(nameDraft) else {
            leaderboardError = .invalidName
            nameDraft = leaderboard.name
            return
        }
        guard name != leaderboard.name else { nameDraft = name; return }
        leaderboardBusy = true
        Task { @MainActor in
            defer { leaderboardBusy = false }
            do { try await leaderboard.join(name: name) } catch let e as LeaderboardError {
                leaderboardError = e
            } catch {}
            nameDraft = leaderboard.name
        }
    }

    /// Turning 使用紀錄回傳 off also leaves the leaderboard (its counts come from the uploaded answers).
    /// Events already queued stay on the phone and are sent only if it is turned on again.
    private func setUsage(_ on: Bool) {
        Haptics.selection()
        usageEnabled = on
        if !on && (leaderboardJoined || leavePending) {
            Task { @MainActor in
                if leaderboard.joined { try? await leaderboard.leave() } else { await leaderboard.retryPendingLeave() }
            }
        }
    }

    // MARK: Reminder

    private var reminderRow: some View {
        row(divider: editingReminder && reminderEnabled) {
            HStack(spacing: 12) {
                Button {
                    if reminderEnabled {
                        withAnimation(.easeInOut(duration: 0.25)) { editingReminder.toggle() }
                    } else {
                        setReminder(true)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("每日提醒").appFont(15)
                            Text(ReminderTimeText.string(minutes: reminderMinutes))
                                .appFont(12, relativeTo: .caption1)
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                        Spacer()
                        if reminderEnabled {
                            Image(systemName: editingReminder ? "chevron.down" : "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(reminderEnabled ? "調整提醒時間" : "")
                Toggle("每日提醒", isOn: Binding(get: { reminderEnabled }, set: { setReminder($0) }))
                    .labelsHidden()
                    .tint(Palette.accent)
            }
        }
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0,
                                      of: .now) ?? .now
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                guard minutes != reminderMinutes else { return }
                reminderMinutes = minutes
                rescheduleReminder()
            })
    }

    private func setReminder(_ on: Bool) {
        Haptics.selection()
        if on {
            reminderEnabled = true
            Task { @MainActor in
                if await StudyReminder.shared.requestAuthorization() {
                    await StudyReminder.shared.refresh(context: context, bank: bank)
                } else {
                    reminderEnabled = false
                    editingReminder = false
                    await StudyReminder.shared.disable()
                    reminderDenied = true
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { editingReminder = false }
            reminderEnabled = false
            Task { @MainActor in await StudyReminder.shared.disable() }
        }
    }

    private func rescheduleReminder() {
        Task { @MainActor in await StudyReminder.shared.refresh(context: context, bank: bank) }
    }

    // MARK: Export

    private func export() {
        do {
            let url = try StudyExport.makeFile(context: context)
            ShareSheet.present(url)
        } catch {
            exportFailed = true
        }
    }

    // MARK: iCloud and import

    private var syncRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud 同步").appFont(15)
                Text(sync.joinPending ? "還沒開始同步；下次開啟 App 時會再檢查 iCloud。" : sync.status.detail)
                    .appFont(12, relativeTo: .caption1)
                    .foregroundStyle(sync.status.isProblem ? Palette.warn : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let decision = sync.joinDecision {
                    Text(decision.settingsText)
                        .appFont(12, relativeTo: .caption1)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(sync.status.title)
                .appFont(15)
                .foregroundStyle(sync.status.isProblem ? Palette.warn : Palette.accent)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    struct ImportMessage {
        let title: String
        let body: String
    }

    /// The export written when this device switched to iCloud's records (「改用 iCloud 上的紀錄」), if still there.
    private var replacedExport: URL? {
        guard sync.joinDecision == .useICloud,
              let path = UserDefaults.standard.string(forKey: FirstJoin.exportPathKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var restoreRow: some View {
        Button { if let url = replacedExport { readImport(.success(url)) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("加回這台原本的紀錄").appFont(15).foregroundStyle(Palette.accent)
                    Text("開始同步前存下的匯出檔；加回後也會同步到另一台")
                        .appFont(12, relativeTo: .caption1)
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func readImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let data = try? Data(contentsOf: url) else { throw StudyImport.Failure.unreadable }
            let preview = try StudyImport.preview(data: data, context: context)
            if preview.summary.isEmpty {
                importMessage = ImportMessage(title: "沒有新的資料", body: "這個檔案裡的作答與筆記都已經在 App 裡了。")
            } else {
                importPreview = preview
            }
        } catch let failure as StudyImport.Failure {
            importMessage = ImportMessage(title: "無法匯入", body: failure.message)
        } catch {
            importMessage = ImportMessage(title: "無法匯入", body: StudyImport.Failure.unreadable.message)
        }
    }

    private func applyImport(_ preview: StudyImport.Preview) {
        do {
            let summary = try StudyImport.apply(preview.document, context: context)
            importMessage = ImportMessage(title: "已匯入", body: "加入了 \(summary.text)。"
                + (summary.schedulesPending ? "複習排程會在下次開啟 App 時重新計算。" : ""))
            rescheduleReminder()
        } catch {
            importMessage = ImportMessage(title: "無法匯入", body: StudyImport.Failure.saveFailed.message)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .appFont(12, relativeTo: .caption1)
            .lineSpacing(3)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { examDate > 0 ? Date(timeIntervalSince1970: examDate) : Calendar.current.startOfDay(for: .now) },
            set: { examDate = Calendar.current.startOfDay(for: $0).timeIntervalSince1970 })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(13, .medium, relativeTo: .footnote)
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        }
    }

    private func row<Content: View>(divider: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content().frame(minHeight: 48)
            if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

/// Presents the system share sheet from the top-most view controller.
@MainActor
enum ShareSheet {
    static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                                 width: 0, height: 0)
        top.present(sheet, animated: true)
    }
}
