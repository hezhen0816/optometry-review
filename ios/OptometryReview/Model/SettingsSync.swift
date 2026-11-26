import Foundation

/// The iCloud key-value store, abstracted for tests.
protocol UbiquitousKeyValueStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

/// Syncs 考試日期, 每日題數, the practice-scope settings (今日範圍 `scope.daily`, 特考, 新題比例 and its custom percent)
/// and the first-visit tip flags between devices through `NSUbiquitousKeyValueStore`; every other setting stays on the
/// device (including the last 自選練習 choice `scope.custom`). Each value travels with the time it was changed, and the newer change wins on both sides.
///
/// Local values stay in UserDefaults (the views use `@AppStorage`), so remote values are written there and local
/// changes are noticed by key-value observing UserDefaults.
@MainActor
final class SettingsSync: NSObject {
    static let shared = SettingsSync(defaults: .standard, store: NSUbiquitousKeyValueStore.default)

    /// UserDefaults keys that sync (also used as the iCloud keys, prefixed).
    static let keys = [SettingsKey.examDate, SettingsKey.dailyGoal, ScopeStore.dailyKey, SettingsKey.includeSpecial,
                       SettingsKey.newRatioMode, SettingsKey.customNewPercent] + SettingsKey.allTips
    static func remoteKey(_ key: String) -> String { "settings." + key }
    static func stampKey(_ key: String) -> String { "settingsSync.\(key).at" }

    private let defaults: UserDefaults
    private let store: UbiquitousKeyValueStoring
    private let now: () -> Date
    private var applyingRemote = false
    private var observing = false
    private var storeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    /// Last seen value of each dotted key. Keys such as "tip.units.shown" and "scope.daily" contain dots, which
    /// key-value observing reads as a key path, so they are noticed through `UserDefaults.didChangeNotification`
    /// and a comparison with this instead.
    private var seenDotted: [String: AnyHashable] = [:]

    /// Keys watched with key-value observing (plain names); the dotted keys are the rest.
    private static let observedKeys = keys.filter { !$0.contains(".") }
    private static let dottedKeys = keys.filter { $0.contains(".") }

    init(defaults: UserDefaults, store: UbiquitousKeyValueStoring, now: @escaping () -> Date = { .now }) {
        self.defaults = defaults
        self.store = store
        self.now = now
    }

    func start() {
        guard !observing else { return }
        observing = true
        for key in Self.observedKeys { defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
        if let kvs = store as? NSUbiquitousKeyValueStore {
            storeObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main) { [weak self] note in
                let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                MainActor.assumeIsolated { self?.remoteChanged(keys: changed) }
            }
        }
        store.synchronize()
        reconcile()
        rememberDotted()
    }

    func stop() {
        guard observing else { return }
        observing = false
        for key in Self.observedKeys { defaults.removeObserver(self, forKeyPath: key) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    // MARK: Merge

    private struct Stamped {
        let value: Any
        let at: Double
    }

    private func remote(_ key: String) -> Stamped? {
        guard let dict = store.object(forKey: Self.remoteKey(key)) as? [String: Any],
              let value = dict["value"], let at = dict["at"] as? Double else { return nil }
        return Stamped(value: value, at: at)
    }

    private func localStamp(_ key: String) -> Double? {
        defaults.object(forKey: Self.stampKey(key)) as? Double
    }

    /// Normalizes a value for one key; nil when it is not a valid value.
    private func normalized(_ value: Any?, for key: String) -> Any? {
        switch key {
        case SettingsKey.examDate:
            guard let d = (value as? NSNumber)?.doubleValue, d.isFinite, d >= 0 else { return nil }
            return d
        case SettingsKey.dailyGoal:
            guard let n = (value as? NSNumber)?.intValue, SettingsKey.dailyGoalRange.contains(n) else { return nil }
            return n
        case let tip where SettingsKey.allTips.contains(tip):
            // Stored as a boolean; iCloud hands back a number.
            guard let n = value as? NSNumber else { return nil }
            return n.boolValue
        case ScopeStore.dailyKey:
            guard let text = value as? String, !text.isEmpty,
                  let _: PracticeScope = ScopeStore.decode(text) else { return nil }
            return text
        case SettingsKey.includeSpecial:
            guard let n = value as? NSNumber else { return nil }
            return n.boolValue
        case SettingsKey.newRatioMode:
            guard let raw = value as? String, NewRatioMode(rawValue: raw) != nil else { return nil }
            return raw
        case SettingsKey.customNewPercent:
            guard let n = (value as? NSNumber)?.intValue, SettingsKey.customNewPercentRange.contains(n) else { return nil }
            return n
        default: return nil
        }
    }

    /// What "changed" means for a dotted key: tips compare as booleans, the scope as a decoded value (its unit set has no
    /// stable text order). Nil when the key is unset or invalid.
    private func identity(_ key: String) -> AnyHashable? {
        guard let value = normalized(defaults.object(forKey: key), for: key) else { return nil }
        if key == ScopeStore.dailyKey, let text = value as? String {
            let scope: PracticeScope? = ScopeStore.decode(text)
            return scope
        }
        return value as? AnyHashable
    }

    private func push(_ key: String, value: Any, at: Double) {
        store.set(["value": value, "at": at], forKey: Self.remoteKey(key))
    }

    private func applyRemote(_ key: String, _ r: Stamped) {
        guard let value = normalized(r.value, for: key) else { return }
        applyingRemote = true
        defaults.set(value, forKey: key)
        defaults.set(r.at, forKey: Self.stampKey(key))
        applyingRemote = false
        if Self.dottedKeys.contains(key) { seenDotted[key] = identity(key) }
    }

    private func rememberDotted() {
        for key in Self.dottedKeys { seenDotted[key] = identity(key) }
    }

    /// Any UserDefaults change: a dotted key that now differs from what this device last saw was changed by her here.
    func defaultsChanged() {
        guard !applyingRemote else { return }
        for key in Self.dottedKeys {
            let current = identity(key)
            guard current != seenDotted[key] else { continue }
            seenDotted[key] = current
            if current != nil { localChanged(key: key) }
        }
    }

    /// Launch: the newer side wins per key. A local value never changed since syncing began has no time and loses to
    /// any synced value; with nothing synced yet it is uploaded.
    func reconcile() {
        SettingsKey.repairDailyGoal(defaults: defaults)
        for key in Self.keys {
            let r = remote(key)
            let localAt = localStamp(key)
            let local = normalized(defaults.object(forKey: key), for: key)
            if let r, r.at > (localAt ?? -.infinity) {
                applyRemote(key, r)
            } else if let local, r == nil || (localAt ?? -.infinity) > r!.at {
                let at = localAt ?? now().timeIntervalSince1970
                defaults.set(at, forKey: Self.stampKey(key))
                push(key, value: local, at: at)
            }
        }
        store.synchronize()
    }

    /// Another device changed a value (or this device signed in to iCloud).
    func remoteChanged(keys changed: [String]?) {
        for key in Self.keys where changed?.contains(Self.remoteKey(key)) ?? true {
            if let r = remote(key), r.at > (localStamp(key) ?? -.infinity) { applyRemote(key, r) }
        }
    }

    /// The user changed a value on this device.
    func localChanged(key: String) {
        guard !applyingRemote, Self.keys.contains(key),
              let value = normalized(defaults.object(forKey: key), for: key) else { return }
        if Self.dottedKeys.contains(key) { seenDotted[key] = identity(key) }
        // Strictly increasing per key, so a quick second change always beats the first even on equal clocks.
        let at = max(now().timeIntervalSince1970, (localStamp(key) ?? 0) + 0.001)
        defaults.set(at, forKey: Self.stampKey(key))
        push(key, value: value, at: at)
        store.synchronize()
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { localChanged(key: keyPath) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.localChanged(key: keyPath) } }
        }
    }
}
