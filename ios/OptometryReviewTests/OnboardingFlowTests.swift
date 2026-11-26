import XCTest
@testable import OptometryReview

/// 0.3.0 first-run flows: which screen a new user, a second device and a 0.2.x upgrade see,
/// and the first-visit tip flags syncing between devices.
final class OnboardingFlowTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "opto.onboarding.\(UUID())"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func inputs(date: Bool = false, icloud: Bool = false, waited: Bool = false) -> OnboardingFlow.Inputs {
        .init(hasExamDate: date, iCloudMayDeliver: icloud, waited: waited)
    }

    // MARK: Stage

    func testNewUserWithoutICloudStartsRightAway() {
        XCTAssertEqual(OnboardingFlow.stage(inputs()), .newUser)
    }

    func testICloudWaitsUpToTheTimeoutThenRunsTheNewUserFlow() {
        XCTAssertEqual(OnboardingFlow.stage(inputs(icloud: true)), .checkingICloud)
        XCTAssertEqual(OnboardingFlow.stage(inputs(icloud: true, waited: true)), .newUser)
        XCTAssertEqual(OnboardingFlow.iCloudWait, 3)
    }

    func testAnExamDateFromICloudMeansSecondDevice() {
        XCTAssertEqual(OnboardingFlow.stage(inputs(date: true)), .secondDevice)
        XCTAssertEqual(OnboardingFlow.stage(inputs(date: true, icloud: true)), .secondDevice, "no waiting once it arrived")
    }

    func testStageIsDecidedOnceChecking() {
        // Still checking: the date arriving switches to the second-device page.
        XCTAssertEqual(OnboardingFlow.next(current: .checkingICloud, inputs(date: true, icloud: true)), .secondDevice)
        // Timeout without a date: new user.
        XCTAssertEqual(OnboardingFlow.next(current: .checkingICloud, inputs(icloud: true, waited: true)), .newUser)
        // First evaluation.
        XCTAssertEqual(OnboardingFlow.next(current: nil, inputs(icloud: true)), .checkingICloud)
        // Once the new-user flow runs, typing a date (or a late iCloud date) never switches the screen.
        XCTAssertEqual(OnboardingFlow.next(current: .newUser, inputs(date: true, icloud: true, waited: true)), .newUser)
        XCTAssertEqual(OnboardingFlow.next(current: .secondDevice, inputs()), .secondDevice)
    }

    func testAnExamDateTypedInUnfinishedSetupIsNotTakenForICloud() {
        let d = suite()
        d.set(1_800_000_000.0, forKey: SettingsKey.examDate)
        XCTAssertTrue(OnboardingFlow.hasRemoteExamDate(defaults: d))
        d.set(true, forKey: OnboardingFlow.setupStartedKey)
        XCTAssertFalse(OnboardingFlow.hasRemoteExamDate(defaults: d), "relaunch mid-tour still runs the new-user flow")
        XCTAssertFalse(OnboardingFlow.hasRemoteExamDate(defaults: suite()), "no date, no second device")
    }

    // MARK: Flags

    func testFinishingAFirstRunWritesAllFlagsAndSkipsTheNewFeaturesSheet() {
        let d = suite()
        d.set(true, forKey: OnboardingFlow.setupStartedKey)
        OnboardingFlow.finishFirstRun(defaults: d)
        XCTAssertTrue(d.bool(forKey: SettingsKey.onboarded))
        XCTAssertTrue(d.bool(forKey: OnboardingFlow.tourDoneKey))
        XCTAssertTrue(d.bool(forKey: OnboardingFlow.whatsNewKey))
        XCTAssertTrue(d.bool(forKey: OnboardingFlow.whatsNewZeroThreeTwoKey))
        XCTAssertNil(d.object(forKey: OnboardingFlow.setupStartedKey))
        XCTAssertFalse(OnboardingFlow.showsWhatsNew(onboarded: d.bool(forKey: SettingsKey.onboarded),
                                                    whatsNewShown: d.bool(forKey: OnboardingFlow.whatsNewKey)))
    }

    func testZeroThreeTwoUserSeesTheSheetOnceWithOnlyTheNewItems() {
        // A 0.3.2 install: onboarded, the 0.3.2 sheet seen, no 0.3.3 flag.
        let d = suite()
        d.set(true, forKey: SettingsKey.onboarded)
        d.set(true, forKey: OnboardingFlow.whatsNewZeroThreeTwoKey)
        XCTAssertEqual(OnboardingFlow.whatsNewKey, "whatsNew.0.3.3")
        XCTAssertTrue(OnboardingFlow.showsWhatsNew(onboarded: true, whatsNewShown: d.bool(forKey: OnboardingFlow.whatsNewKey)))
        XCTAssertFalse(OnboardingFlow.includesZeroThreeTwo(zeroThreeTwoShown: d.bool(forKey: OnboardingFlow.whatsNewZeroThreeTwoKey)))
        OnboardingFlow.markWhatsNewSeen(defaults: d)
        XCTAssertFalse(OnboardingFlow.showsWhatsNew(onboarded: true, whatsNewShown: d.bool(forKey: OnboardingFlow.whatsNewKey)))
    }

    func testSkippingZeroThreeTwoSeesTheCombinedSheetAndDismissSetsBothFlags() {
        // An install that never saw the 0.3.2 sheet: onboarded, no 0.3.2 or 0.3.3 keys.
        let d = suite()
        d.set(true, forKey: SettingsKey.onboarded)
        d.set(true, forKey: "whatsNew.0.3")
        d.set(1_800_000_000.0, forKey: SettingsKey.examDate)
        XCTAssertTrue(OnboardingFlow.showsWhatsNew(onboarded: true, whatsNewShown: d.bool(forKey: OnboardingFlow.whatsNewKey)))
        XCTAssertTrue(OnboardingFlow.includesZeroThreeTwo(zeroThreeTwoShown: d.bool(forKey: OnboardingFlow.whatsNewZeroThreeTwoKey)))
        // Never the tour: it is only reachable from the not-onboarded stages and 使用說明.
        XCTAssertNil(d.object(forKey: OnboardingFlow.tourDoneKey))
        OnboardingFlow.markWhatsNewSeen(defaults: d)
        XCTAssertTrue(d.bool(forKey: OnboardingFlow.whatsNewKey))
        XCTAssertTrue(d.bool(forKey: OnboardingFlow.whatsNewZeroThreeTwoKey))
        XCTAssertFalse(OnboardingFlow.showsWhatsNew(onboarded: true, whatsNewShown: d.bool(forKey: OnboardingFlow.whatsNewKey)))
        XCTAssertEqual(d.double(forKey: SettingsKey.examDate), 1_800_000_000.0)
    }

    func testWhatsNewKeyVersionMatchesTheBundleVersion() {
        let version = Bundle(for: QuestionBank.self).infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertEqual(OnboardingFlow.whatsNewKey, "whatsNew.\(version ?? "?")")
    }

    func testNotOnboardedNeverShowsTheNewFeaturesSheet() {
        XCTAssertFalse(OnboardingFlow.showsWhatsNew(onboarded: false, whatsNewShown: false))
    }

    // MARK: Tour

    func testTourHasEightPagesAndFiveOfThemExplainWhenToUseTheTab() {
        XCTAssertEqual(TourPage.count, 8)
        XCTAssertEqual(TourPage.allCases.filter { $0.when != nil }.count, 5)
        XCTAssertEqual(TourPage.allCases.map(\.kicker).prefix(5), ["五個分頁", "五個分頁", "五個分頁", "五個分頁", "五個分頁"])
    }

    // MARK: Tips

    func testFiveFirstVisitTipsAreRegisteredAndTheRetiredOneIsGone() {
        let keys = SettingsKey.allTips
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in ["tip.units.shown", "tip.handout.shown", "tip.aiQuestion.shown", "tip.aiMistakes.shown", "tip.papers.shown",
                    "tip.reason.shown", "tip.examGrid.shown", "tip.unsure.shown"] {
            XCTAssertTrue(keys.contains(key), key)
        }
        XCTAssertFalse(keys.contains("tip.unitSwitch.shown"))
    }

    @MainActor
    func testTipShownFlagsTravelBetweenDevicesAndTheResetClearsThemEverywhere() {
        let kvs = FakeKVS()
        let tip = SettingsKey.tipUnitsShown
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let phone = suite()
        let phoneSync = SettingsSync(defaults: phone, store: kvs, now: { clock })
        phoneSync.start()
        defer { phoneSync.stop() }
        phone.set(true, forKey: tip)                       // she dismisses the tip on the phone
        phoneSync.defaultsChanged()                        // (the defaults-change notification, run directly)
        XCTAssertEqual((kvs.values["settings." + tip] as? [String: Any])?["value"] as? Bool, true)

        // A new iPad takes it on first launch: no second showing.
        let pad = suite()
        let padSync = SettingsSync(defaults: pad, store: kvs, now: { clock })
        padSync.reconcile()
        XCTAssertTrue(pad.bool(forKey: tip))

        // 重新顯示提示 on the iPad later clears it on the phone too.
        clock = clock.addingTimeInterval(60)
        pad.set(false, forKey: tip)
        padSync.localChanged(key: tip)
        phoneSync.remoteChanged(keys: ["settings." + tip])
        XCTAssertFalse(phone.bool(forKey: tip))
        XCTAssertTrue(SettingsKey.tipPending(tip, defaults: phone))
    }

    @MainActor
    func testTipFlagsAreSyncedKeysButOnlyBooleanValuesAreTaken() {
        XCTAssertTrue(SettingsKey.allTips.allSatisfy(SettingsSync.keys.contains))
        let kvs = FakeKVS()
        kvs.values["settings.tip.units.shown"] = ["value": "yes", "at": 5.0]
        let d = suite()
        SettingsSync(defaults: d, store: kvs).reconcile()
        XCTAssertFalse(d.bool(forKey: SettingsKey.tipUnitsShown), "a string value is ignored")
    }

    @MainActor
    func testUnrelatedDefaultsChangesDoNotRewriteTipTimes() {
        let kvs = FakeKVS()
        let d = suite()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = SettingsSync(defaults: d, store: kvs, now: { clock })
        sync.start()
        defer { sync.stop() }
        d.set(true, forKey: SettingsKey.tipHandoutShown)
        sync.defaultsChanged()
        let first = (kvs.values["settings.tip.handout.shown"] as? [String: Any])?["at"] as? Double
        XCTAssertNotNil(first)
        clock = clock.addingTimeInterval(600)
        d.set("x", forKey: "somethingElse")
        sync.defaultsChanged()
        sync.defaultsChanged()
        XCTAssertEqual((kvs.values["settings.tip.handout.shown"] as? [String: Any])?["at"] as? Double, first,
                       "no change to the tip, so its time stays")
    }

    private final class FakeKVS: UbiquitousKeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() -> Bool { true }
    }
}
