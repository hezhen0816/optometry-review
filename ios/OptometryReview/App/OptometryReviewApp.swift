import SwiftUI
import SwiftData

private struct QuestionBankKey: EnvironmentKey {
    static let defaultValue = QuestionBank(questions: [])
}

extension EnvironmentValues {
    var questionBank: QuestionBank {
        get { self[QuestionBankKey.self] }
        set { self[QuestionBankKey.self] = newValue }
    }
}

@main
struct OptometryReviewApp: App {
    @UIApplicationDelegateAdaptor(UsageAppDelegate.self) private var appDelegate
    @State private var loader: AppStoreLoader
    let bank: QuestionBank

    init() {
        #if DEBUG
        CloudSchemaInit.runIfRequested()
        #endif
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let wantsCloud = !isTesting && CloudSyncConfig.wantsCloud()
        let bank = isTesting ? QuestionBank(questions: []) : QuestionBank.loadFromBundle()
        self.bank = bank
        if !isTesting {
            ScopeStore.migrateLegacyYears(availableYears: bank.availableYears)
            YearFilterStore.migrateLegacy()
        }
        // The store opens right away, except on the first iCloud launch of a device that already has answers:
        // then the first-join check (and maybe her choice) comes first (FirstJoin.swift).
        _loader = State(initialValue: MainActor.assumeIsolated {
            #if DEBUG
            if !isTesting { StudyDataStore.corruptStoreIfRequested() }
            #endif
            return AppStoreLoader(inMemory: isTesting, cloud: wantsCloud) { container, syncing in
                AIExplainer.shared = AIExplainer(config: AIConfig.load(), context: container.mainContext)
                _ = UsageLog.shared
                HandoutAsker.shared = HandoutAsker(config: AIConfig.load())
                #if DEBUG
                DebugLaunch.apply(container: container, bank: bank)
                #endif
                SettingsKey.repairDailyGoal()
                if wantsCloud {
                    CloudSync.shared.start(container: container, enabled: syncing)
                    SettingsSync.shared.start()
                    if syncing { FirstJoin.writeRecord(context: container.mainContext) }
                }
            }
        })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch loader.phase {
                case .ready(let container):
                    RootView()
                        .environment(\.questionBank, bank)
                        .modelContainer(container)
                case .checking:
                    JoinCheckingView()
                case let .asking(local, remote, recommendICloud):
                    JoinChoiceView(local: local, remote: remote, recommendICloud: recommendICloud) { loader.choose($0) }
                }
            }
            .tint(Palette.accent)
        }
    }
}

final class UsageAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        UsageLog.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(\.questionBank) private var bank
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.examDate) private var examDate: Double = 0
    @State private var recovery = DataStoreRecovery.shared
    @State private var saveFailure = SaveFailureNotice.shared
    /// First run flow, decided once (see `OnboardingFlow.next`).
    @State private var stage: OnboardingFlow.Stage?
    @State private var waited = false
    /// New user: past the welcome page, on 開始前的設定.
    @State private var welcomeDone = false
    @State private var showTour = false
    @State private var usageEnvironmentReady = false

    var body: some View {
        ZStack {
            if onboarded {
                MainTabView()
            } else {
                switch stage ?? .checkingICloud {
                case .checkingICloud:
                    PlanCheckingView()
                case .newUser:
                    if welcomeDone {
                        OnboardingView { showTour = true }
                            .transition(.move(edge: .trailing))
                    } else {
                        WelcomeView { withAnimation(.easeInOut(duration: 0.3)) { welcomeDone = true } }
                            .transition(.move(edge: .leading))
                    }
                case .secondDevice:
                    SecondDeviceView(onStart: { OnboardingFlow.finishFirstRun() }, onTour: { showTour = true })
                }
            }
        }
        .fullScreenCover(isPresented: $showTour) {
            TourView(mode: .firstRun) { OnboardingFlow.finishFirstRun() }
                .presentationBackground(.clear)
        }
        .task {
            guard !onboarded else { return }
            refreshStage()
            if stage == .checkingICloud {
                try? await Task.sleep(for: .seconds(OnboardingFlow.iCloudWait))
                waited = true
                refreshStage()
            }
        }
        .onChange(of: examDate) { refreshStage() }
        .alert("學習紀錄無法開啟", isPresented: Binding(get: { recovery.pending }, set: { _ in })) {
            Button("知道了") { recovery.acknowledge() }
        } message: {
            Text(recovery.usedInMemoryStore
                 ? "舊資料已保留；這次的作答不會儲存，請關掉 App 再開一次。"
                 : "舊資料已另存備份，App 以空白紀錄重新開始。")
        }
        .alert("作答沒有存到", isPresented: Binding(get: { saveFailure.visible }, set: { saveFailure.visible = $0 })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("這題的作答沒有存進學習紀錄。請再答一次；若一直出現，請關掉 App 再開。")
        }
        .background { UsageEnvironmentProbe { usageEnvironmentReady = true }.allowsHitTesting(false) }
        .task { await refreshReminder() }
        .task(id: scenePhase == .active && usageEnvironmentReady) {
            guard scenePhase == .active, usageEnvironmentReady, !UsageLog.runningTests else { return }
            let reminder = await StudyReminder.shared.usageStatus()
            guard scenePhase == .active, !Task.isCancelled else { return }
            UsageLog.shared.sceneActive(fields: reminder)
        }
        .onAppear {
            if scenePhase == .active {
                Task { await InsightsStore.shared.refreshIfNeeded() }
                Task { await UpdateNoticeStore.shared.refreshIfNeeded() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await LeaderboardModel.shared.retryPendingLeave() }
                Task { await InsightsStore.shared.refreshIfNeeded() }
                Task { await UpdateNoticeStore.shared.refreshIfNeeded() }
            }
            else if phase == .background { UsageLog.shared.sceneBackground() }
            if phase == .active || phase == .background {
                Task { await refreshReminder() }
            }
        }
    }

    /// iCloud key-value storage only delivers to an install with cloud sync and an iCloud account.
    private func refreshStage() {
        guard !onboarded else { return }
        let mayDeliver = CloudSyncConfig.wantsCloud() && FileManager.default.ubiquityIdentityToken != nil
        stage = OnboardingFlow.next(current: stage, .init(hasExamDate: OnboardingFlow.hasRemoteExamDate(),
                                                          iCloudMayDeliver: mayDeliver, waited: waited))
    }

    @MainActor
    private func refreshReminder() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        await StudyReminder.shared.refresh(context: context, bank: bank)
    }
}
