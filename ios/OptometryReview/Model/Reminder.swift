import Foundation
import SwiftData
import UserNotifications

/// Calendar arithmetic kept independent of notification authorization and delivery.
enum ReminderSchedule {
    static func dates(minutes: Int, goalMet: Bool, now: Date, calendar: Calendar = .current) -> [Date] {
        let minutes = min(1439, max(0, minutes))
        let today = calendar.startOfDay(for: now)
        return (0...7).compactMap { offset -> Date? in
            guard !(offset == 0 && goalMet),
                  let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let time = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  time > now else { return nil }
            return time
        }.prefix(7).map { $0 }
    }
}

@MainActor
final class StudyReminder {
    static let shared = StudyReminder()
    static let identifierPrefix = "opto.daily."

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var generation = 0

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    /// Reads authorization without prompting or changing notification requests.
    func usageStatus() async -> [String: Any] {
        let settings = await center.notificationSettings()
        let authorization: String
        switch settings.authorizationStatus {
        case .authorized: authorization = "authorized"
        case .denied: authorization = "denied"
        case .notDetermined: authorization = "notDetermined"
        case .provisional: authorization = "provisional"
        case .ephemeral: authorization = "ephemeral"
        @unknown default: authorization = "unknown"
        }
        return ["notificationAuthorization": authorization,
                "reminderEnabled": defaults.bool(forKey: SettingsKey.reminderEnabled),
                "reminderMinutes": min(1439, max(0, defaults.object(forKey: SettingsKey.reminderMinutes) as? Int
                                              ?? SettingsKey.defaultReminderMinutes))]
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces only our requests with seven upcoming local-day reminders. Never requests permission itself.
    func reschedule(goalMet: Bool, now: Date = .now) async {
        generation += 1
        let current = generation
        let pending = await center.pendingNotificationRequests()
        guard current == generation else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) })
        guard defaults.bool(forKey: SettingsKey.reminderEnabled) else { return }
        let minutes = defaults.object(forKey: SettingsKey.reminderMinutes) as? Int ?? SettingsKey.defaultReminderMinutes
        for date in ReminderSchedule.dates(minutes: minutes, goalMet: goalMet, now: now) {
            guard current == generation, defaults.bool(forKey: SettingsKey.reminderEnabled) else { return }
            let content = UNMutableNotificationContent()
            content.title = "驗光錯題本"
            content.body = "今天還沒練到目標題數，花幾分鐘練一下吧。"
            content.sound = .default
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            components.timeZone = Calendar.current.timeZone
            let id = Self.identifierPrefix + String(Int(date.timeIntervalSince1970)) + ".\(current)"
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            if current != generation {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                return
            }
        }
    }

    func disable() async {
        defaults.set(false, forKey: SettingsKey.reminderEnabled)
        await reschedule(goalMet: false)
    }
}

extension StudyReminder {
    /// Reschedules with today's goal progress from the study store.
    func refresh(context: ModelContext, bank: QuestionBank, now: Date = .now) async {
        let defaults = UserDefaults.standard
        let goal = SettingsKey.sanitizedDailyGoal(defaults.object(forKey: SettingsKey.dailyGoal))
        let summary = StudyStore(context: context).todaySummary(bank: bank,
            includeSpecial: defaults.bool(forKey: SettingsKey.includeSpecial), goal: goal, now: now)
        await reschedule(goalMet: summary.goalMet(goal), now: now)
    }
}

/// "晚上 9:00" style text for minutes after local midnight, using the same day periods as the zh_Hant time picker.
enum ReminderTimeText {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "B h:mm"
        return f
    }()

    static func string(minutes: Int) -> String {
        let m = min(1439, max(0, minutes))
        let date = Calendar(identifier: .gregorian).date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now) ?? .now
        return formatter.string(from: date)
    }
}
