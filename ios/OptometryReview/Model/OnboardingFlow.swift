import Foundation

/// Which first-run flow the root view shows (0.3.0). Pure decisions only; the views live in
/// OnboardingViews.swift and TourViews.swift.
enum OnboardingFlow {
    /// 「0.3.3 版新功能」 sheet flag. Local to the device (not iCloud-synced), like the earlier ones.
    static let whatsNewKey = "whatsNew.0.3.3"
    /// The 0.3.2 sheet's flag: still read, so someone who skipped 0.3.2 sees its items too. Older flags (`whatsNew.0.3`, `whatsNew.0.2`) are not read any more.
    static let whatsNewZeroThreeTwoKey = "whatsNew.0.3.2"
    /// The full tour was shown (or skipped) on this device's first run.
    static let tourDoneKey = "tour.0.3.done"
    /// Set when a new user leaves 開始前的設定 (the exam date is saved then); cleared at the end of the first run. A
    /// relaunch in between still runs the new-user flow instead of mistaking her own date for one from iCloud.
    static let setupStartedKey = "onboarding.setupStarted"
    /// How long a device that was never onboarded waits for iCloud key-value storage to deliver the exam date.
    static let iCloudWait: TimeInterval = 3

    enum Stage: Equatable {
        /// iCloud may still deliver the study plan: a short check screen.
        case checkingICloud
        /// 開場 → 開始前的設定 → 導覽.
        case newUser
        /// iCloud already holds a study plan: only this device's 使用紀錄回傳 is asked.
        case secondDevice
    }

    struct Inputs: Equatable {
        /// An exam date is stored on this device (synced from iCloud or typed in).
        var hasExamDate: Bool
        /// iCloud key-value storage can deliver values to this install (cloud sync wanted and an iCloud account).
        var iCloudMayDeliver: Bool
        /// The wait for iCloud is over.
        var waited: Bool
    }

    /// Stage for a device that is not onboarded.
    static func stage(_ inputs: Inputs) -> Stage {
        if inputs.hasExamDate { return .secondDevice }
        if inputs.iCloudMayDeliver && !inputs.waited { return .checkingICloud }
        return .newUser
    }

    /// Re-evaluates only while still checking: once the new-user flow runs, typing an exam date must not switch it to
    /// the second-device screen, and a late iCloud value only prefills the settings.
    static func next(current: Stage?, _ inputs: Inputs) -> Stage {
        if let current, current != .checkingICloud { return current }
        return stage(inputs)
    }

    /// What the root view shows once onboarded: the 新功能 sheet for people who have not seen the 0.3.3 one.
    static func showsWhatsNew(onboarded: Bool, whatsNewShown: Bool) -> Bool {
        onboarded && !whatsNewShown
    }

    /// Whether the sheet also lists the 0.3.2 changes: the person never saw the 0.3.2 sheet.
    static func includesZeroThreeTwo(zeroThreeTwoShown: Bool) -> Bool { !zeroThreeTwoShown }

    /// 「知道了」: both sheets are done for good.
    static func markWhatsNewSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: whatsNewKey)
        defaults.set(true, forKey: whatsNewZeroThreeTwoKey)
    }

    /// End of a first run (new user or second device, tour finished or skipped): never shows the 新功能 sheet.
    static func finishFirstRun(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: setupStartedKey)
        defaults.set(true, forKey: tourDoneKey)
        markWhatsNewSeen(defaults: defaults)
        defaults.set(true, forKey: SettingsKey.onboarded)
    }

    /// An exam date that came from somewhere else: stored, and not typed in by this device's own unfinished setup.
    static func hasRemoteExamDate(defaults: UserDefaults = .standard) -> Bool {
        defaults.double(forKey: SettingsKey.examDate) > 0 && !defaults.bool(forKey: setupStartedKey)
    }
}
