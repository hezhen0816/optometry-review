import SwiftUI

/// New user, page 1: single welcome page (no carousel).
struct WelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image("WelcomeIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Palette.scrim.opacity(0.18), radius: 7, y: 4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("驗光錯題本").headingFont(34)
                        Text("用考選部歷屆試題準備驗光師國考：照單元讀重點講義、練歷屆題，答錯的題自動收集，照遺忘的節奏排進每天的複習。")
                            .appFont(17)
                            .lineSpacing(6)
                            .foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        bullet("每天約 20 題，先練該複習的錯題")
                        bullet("每個單元有重點講義，計算題另有 AI 題")
                        bullet("單科模擬與五科連考，推估能不能及格")
                        bullet("iPhone、iPad 用 iCloud 自動同步")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 84)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .readableScrollWidth()
            .scrollBounceBehavior(.basedOnSize)
            Button("下一步", action: onStart)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .readableBarWidth()
                .padding(.bottom, 12)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.accent)
            Text(text).appFont(15)
        }
    }
}

/// What 使用紀錄回傳 sends, shared by 首次設定 and 設定.
enum UsageDisclosure {
    static let short = "作答紀錄（含你選的選項）、使用畫面、操作、裝置環境與設定，用來改進 App、分析弱點與讀書夥伴；不含筆記或提問原文"
    static let full = "會把作答紀錄、使用的畫面與操作、裝置環境、複習與提醒狀態及設定變更傳到開發者的伺服器，用來改進 App 和計算讀書夥伴的本週紀錄。也會傳你選了哪個選項，用來分析你的弱點。不傳筆記或提問原文。可隨時在設定關閉。"
}

/// New user, page 2: exam date, daily count and 使用紀錄回傳. 「下一步」 goes on to the tour.
struct OnboardingView: View {
    let onNext: () -> Void

    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true
    @State private var pickedDate: Date?
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("開始前的設定").headingFont(32)
                        Text("題目來自考選部 106～115 年驗光師歷屆試題。這些之後都可以在設定修改。")
                            .appFont(15).lineSpacing(5)
                            .foregroundStyle(Palette.muted)
                    }
                    dateSection
                    goalSection
                    usageSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .readableScrollWidth()
            .scrollBounceBehavior(.basedOnSize)
            Button("下一步", action: next)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .readableBarWidth()
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .tint(Palette.accent)
        // iCloud may deliver the plan a moment after launch: show whatever arrives.
        .onAppear(perform: prefill)
        .onChange(of: examDate) { prefill() }
    }

    private func prefill() {
        if pickedDate == nil, examDate > 0 { pickedDate = Date(timeIntervalSince1970: examDate) }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("考試日期").appFont(15, .bold)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if pickedDate == nil { pickedDate = defaultExamGuess() }
                    showPicker.toggle()
                }
            } label: {
                HStack {
                    Text(pickedDate.map { DateText.fullDate.string(from: $0) } ?? "選擇考試日期")
                        .appFont(17)
                        .foregroundStyle(pickedDate == nil ? Palette.muted : Palette.ink)
                    Spacer()
                    Image(systemName: "calendar").foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.controlBorder, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pickedDate.map { "考試日期 \(DateText.fullDate.string(from: $0))" } ?? "選擇考試日期")
            if showPicker {
                DatePicker("考試日期",
                           selection: Binding(get: { pickedDate ?? defaultExamGuess() }, set: { pickedDate = $0 }),
                           in: Calendar.current.startOfDay(for: .now)...,
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                    .transition(.opacity)
            }
            Text("正式日期以考選部公告為準；用來算倒數與每日進度。")
                .appFont(13, relativeTo: .footnote)
                .foregroundStyle(Palette.muted)
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每天想做幾題").appFont(15, .bold)
            HStack(spacing: 12) {
                stepButton("−", label: "減少 5 題") { dailyGoal = max(SettingsKey.dailyGoalRange.lowerBound, dailyGoal - SettingsKey.dailyGoalStep) }
                    .disabled(dailyGoal <= SettingsKey.dailyGoalRange.lowerBound)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(dailyGoal)").appFont(34, .bold).monospacedDigit()
                    Text(" 題").appFont(16).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                stepButton("+", label: "增加 5 題") { dailyGoal = min(SettingsKey.dailyGoalRange.upperBound, dailyGoal + SettingsKey.dailyGoalStep) }
                    .disabled(dailyGoal >= SettingsKey.dailyGoalRange.upperBound)
            }
            Text("先練該複習的錯題，不夠再從弱科補新題。")
                .appFont(13, relativeTo: .footnote)
                .foregroundStyle(Palette.muted)
        }
    }

    private var usageSection: some View {
        UsageToggleSection(title: "使用紀錄回傳", isOn: $usageEnabled)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.selection()
            action()
        }) {
            Text(symbol).appFont(22)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.controlBorder, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func defaultExamGuess() -> Date {
        Calendar.current.date(byAdding: .month, value: 4, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private func next() {
        UserDefaults.standard.set(true, forKey: OnboardingFlow.setupStartedKey)
        if let pickedDate { examDate = Calendar.current.startOfDay(for: pickedDate).timeIntervalSince1970 }
        onNext()
    }
}

/// 使用紀錄回傳 switch with the full disclosure; first-run settings and the second-device page share it.
struct UsageToggleSection: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(title).appFont(15, .bold)
            }
            .tint(Palette.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            Text(UsageDisclosure.full)
                .appFont(13, relativeTo: .footnote)
                .lineSpacing(3)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Second device: iCloud already holds the study plan, so only this device's 使用紀錄回傳 is asked.
struct SecondDeviceView: View {
    let onStart: () -> Void
    let onTour: () -> Void

    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @AppStorage(SettingsKey.dailyGoal) private var dailyGoal = SettingsKey.defaultDailyGoal
    @AppStorage(SettingsKey.usageLogEnabled) private var usageEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.accentSoft))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已接上 iCloud 的紀錄").headingFont(32)
                        Text("這台會用你在另一台的作答、錯題排程、筆記和收藏，之後兩台自動同步。讀書計畫也一起帶過來：")
                            .appFont(15).lineSpacing(5)
                            .foregroundStyle(Palette.muted)
                    }
                    VStack(spacing: 0) {
                        planRow("考試日期", examDate > 0 ? DateText.fullDate.string(from: Date(timeIntervalSince1970: examDate)) : "—",
                                divider: true)
                        planRow("每天題數", "\(dailyGoal) 題", divider: false)
                    }
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                    UsageToggleSection(title: "這台的使用紀錄回傳", isOn: $usageEnabled)
                }
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .readableScrollWidth()
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 4) {
                Button("開始使用", action: onStart)
                    .buttonStyle(PrimaryButtonStyle())
                Button("先看導覽", action: onTour)
                    .appFont(16, .medium)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .readableBarWidth()
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.ground.ignoresSafeArea())
        .tint(Palette.accent)
        .trackScreen("secondDevice")
    }

    private func planRow(_ title: String, _ value: String, divider: Bool) -> some View {
        HStack {
            Text(title).appFont(15)
            Spacer()
            Text(value).appFont(15).foregroundStyle(Palette.accent).monospacedDigit()
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(Palette.hairline).frame(height: 1) } }
    }
}

/// Shown for up to `OnboardingFlow.iCloudWait` seconds on a device that was never onboarded, while iCloud
/// key-value storage may still deliver the exam date.
struct PlanCheckingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在檢查 iCloud 上的讀書計畫…").appFont(15).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }
}
