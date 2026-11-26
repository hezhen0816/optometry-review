import Foundation
import SwiftData
import CoreData
import CloudKit
import Observation
import OSLog

/// iCloud sync of the study store. SwiftData mirrors the store to the private CloudKit database;
/// this file decides when sync is on, protects the data before the first sync, merges duplicates after imports,
/// and reports a plain status for 設定 › 資料.
enum CloudSyncConfig {
    static let configuredContainerID = Bundle.main.object(forInfoDictionaryKey: "OptometryCloudContainer") as? String
    static var containerID: String { configuredContainerID ?? "iCloud.org.example.optometryreview" }
    /// Set (per store file) once the store files were copied and exported before the first launch with CloudKit.
    static func firstBackupKey(_ storeURL: URL) -> String { "cloudSync.firstBackupDone." + storeURL.lastPathComponent }
    /// Last failed backup attempt (per store file); a failed backup is retried at most once a day.
    static func backupAttemptKey(_ storeURL: URL) -> String { "cloudSync.firstBackupTried." + storeURL.lastPathComponent }
    static let backupRetryInterval: TimeInterval = 24 * 60 * 60
    /// Merge at most once per this many seconds after iCloud imports.
    static let mergeDelay: TimeInterval = 2
    /// DEBUG builds sync only when launched with this argument, and then with their own store file
    /// (`debugCloudStoreName`), so data seeded or wiped by the debug launch arguments never reaches iCloud.
    static let debugCloudArgument = "-iCloud"
    static let debugCloudStoreName = "icloud-debug.store"
    /// DEBUG launch arguments that wipe or seed data: never together with iCloud.
    static let localOnlyArguments: Set<String> = ["-localStore", "-resetAll", "-resetAI", "-seedDemo", "-seedMocks",
        "-seedHistory", "-seedDemoLight", "-seedAIMarkers", "-seedFullMock", "-corruptStore"]

    static func wantsCloud(arguments: [String] = ProcessInfo.processInfo.arguments,
                           containerID: String? = configuredContainerID) -> Bool {
        guard let containerID, containerID.hasPrefix("iCloud.") else { return false }
        #if DEBUG
        return arguments.contains(debugCloudArgument) && localOnlyArguments.isDisjoint(with: arguments)
        #else
        return true
        #endif
    }

    /// The store file the app opens: the default store, except a DEBUG build with iCloud uses its own file.
    @MainActor
    static func storeConfiguration(cloud: Bool) -> ModelConfiguration {
        #if DEBUG
        if cloud {
            let url = StudyDataStore.localConfiguration.url.deletingLastPathComponent()
                .appendingPathComponent(debugCloudStoreName)
            return ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)
        }
        #endif
        return StudyDataStore.localConfiguration
    }
}

/// Before the first launch with CloudKit: copy the store files to `StoreBackups/before-icloud-<time>/` and write an
/// export file next to them. Runs once per store file (flag in UserDefaults); a fresh install has nothing to protect.
/// After a failure sync stays off and the backup is retried at most once a day (it copies the whole store).
@MainActor
enum FirstSyncBackup {
    /// Returns true when sync may start (backup done now or earlier, or nothing to back up).
    static func ensure(storeURL: URL, defaults: UserDefaults = .standard, now: Date = .now,
                       export: ((URL) throws -> Void)? = nil) -> Bool {
        let doneKey = CloudSyncConfig.firstBackupKey(storeURL), triedKey = CloudSyncConfig.backupAttemptKey(storeURL)
        if defaults.bool(forKey: doneKey) { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else {
            defaults.set(true, forKey: doneKey)
            return true
        }
        if let tried = defaults.object(forKey: triedKey) as? Date,
           now.timeIntervalSince(tried) < CloudSyncConfig.backupRetryInterval, now >= tried { return false }
        defaults.set(now, forKey: triedKey)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var folder = storeURL.deletingLastPathComponent().appendingPathComponent("StoreBackups", isDirectory: true)
            .appendingPathComponent("before-icloud-" + formatter.string(from: now), isDirectory: true)
        if fm.fileExists(atPath: folder.path) { folder.appendPathComponent(UUID().uuidString, isDirectory: true) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
                }
            }
            try (export ?? { try exportStore(at: storeURL, into: $0, now: now) })(folder)
        } catch {
            Logger(subsystem: "org.example.optometryreview", category: "CloudSync")
                .error("First-sync backup failed: \(String(describing: error), privacy: .private)")
            return false
        }
        defaults.set(true, forKey: doneKey)
        defaults.removeObject(forKey: triedKey)
        return true
    }

    /// Opens the store locally (running any pending lightweight migration) only long enough to export it.
    private static func exportStore(at url: URL, into folder: URL, now: Date) throws {
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: StudyDataStore.schema, migrationPlan: StudyMigrationPlan.self,
                                           configurations: [config])
        _ = try StudyExport.makeFile(context: container.mainContext, now: now, folder: folder, logUsage: false)
    }
}

/// Coalesces triggers: runs `action` once `delay` seconds after the last trigger, never re-entrantly.
@MainActor
final class DebouncedRunner {
    let delay: TimeInterval
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var running = false
    private var rerun = false
    private(set) var runCount = 0

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func trigger() {
        pending?.cancel()
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func fire() {
        guard !running else { rerun = true; return }
        running = true
        action()
        runCount += 1
        running = false
        if rerun {
            rerun = false
            trigger()
        }
    }
}

/// Sync state for 設定 › 資料, plus the merge after iCloud imports.
@MainActor @Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Status: Equatable {
        case synced, syncing, noAccount, quotaExceeded, offline, unavailable

        var title: String {
            switch self {
            case .synced: "已同步"
            case .syncing: "同步中"
            case .noAccount: "未登入 iCloud"
            case .quotaExceeded: "iCloud 空間不足"
            case .offline: "等待網路"
            case .unavailable: "目前無法同步"
            }
        }

        var detail: String {
            switch self {
            case .synced, .syncing:
                "作答、排程、筆記、收藏與練習設定（考試日期、每日題數、範圍、新題比例），會在登入同一個 Apple 帳號的 iPhone、iPad 間自動同步。"
            case .noAccount:
                "到 iOS「設定」登入 Apple 帳號並開啟 iCloud 後會自動同步；在那之前資料只存在這台裝置。"
            case .quotaExceeded:
                "新的作答先存在這台裝置；到 iOS「設定」清出 iCloud 空間後會自動繼續同步。"
            case .offline:
                "資料先存在這台裝置，連上網路後會自動同步。"
            case .unavailable:
                "資料仍存在這台裝置，稍後會自動再試。"
            }
        }

        var isProblem: Bool { self == .noAccount || self == .quotaExceeded || self == .unavailable }
    }

    private(set) var status: Status = .unavailable
    private(set) var enabled = false
    /// Sync is off this launch because the first-join check could not finish; it runs again next launch.
    private(set) var joinPending = false
    @ObservationIgnored private var localOnlyStatus: Status?
    /// How this device joined iCloud (shown in 設定 › 資料); nil before it has.
    var joinDecision: FirstJoin.Decision?
    /// Bumped after each post-import merge, so screens that compute their numbers once (今日) recompute.
    private(set) var importVersion = 0
    @ObservationIgnored private var account: CKAccountStatus?
    @ObservationIgnored private var running = Set<UUID>()
    @ObservationIgnored private var lastError: Error?
    /// Set by `start`; tests set it directly.
    @ObservationIgnored var merger: DebouncedRunner?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Call once with the app's container. `enabled` is false when the store opened local-only.
    func start(container: ModelContainer, enabled: Bool) {
        self.enabled = enabled
        guard enabled, observers.isEmpty else { refresh(); return }
        merger = DebouncedRunner(delay: CloudSyncConfig.mergeDelay) { [weak self] in
            Self.merge(container: container)
            FirstJoin.writeRecord(context: container.mainContext)
            self?.importVersion += 1
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate != nil
            let info = (id: event.identifier, type: event.type, finished: finished, ok: event.succeeded, error: event.error)
            MainActor.assumeIsolated { self?.handle(info.id, type: info.type, finished: info.finished, succeeded: info.ok, error: info.error) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        })
        refresh()
        refreshAccount()
    }

    func refreshAccount() {
        guard enabled else { return }
        CKContainer(identifier: CloudSyncConfig.containerID).accountStatus { [weak self] status, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.account = status
                    self?.refresh()
                }
            }
        }
    }

    func handle(_ id: UUID, type: NSPersistentCloudKitContainer.EventType, finished: Bool, succeeded: Bool, error: Error?) {
        if finished {
            running.remove(id)
            if succeeded { lastError = nil } else if let error { lastError = error }
            // Duplicates only appear when another device's rows arrive.
            if type == .import && succeeded { merger?.trigger() }
        } else {
            running.insert(id)
        }
        refresh()
    }

    private func refresh() {
        status = enabled || localOnlyStatus == nil
            ? Self.status(enabled: enabled, account: account, inProgress: !running.isEmpty, error: lastError)
            : localOnlyStatus!
    }

    /// The first-join check could not finish: sync stays off this launch, showing why.
    func showLocalOnly(_ status: Status) {
        localOnlyStatus = status
        joinPending = true
        refresh()
    }

    nonisolated static func status(enabled: Bool, account: CKAccountStatus?, inProgress: Bool, error: Error?) -> Status {
        guard enabled else { return .unavailable }
        switch account {
        case .noAccount: return .noAccount
        case .restricted, .temporarilyUnavailable: return .unavailable
        default: break
        }
        if let error, let problem = classify(error) { return problem }
        if inProgress { return .syncing }
        return account == .available ? .synced : .syncing
    }

    /// Maps a CloudKit error to a status; nil for transient errors CloudKit retries by itself.
    nonisolated static func classify(_ error: Error) -> Status? {
        let ns = error as NSError
        if ns.domain == CKErrorDomain, let code = CKError.Code(rawValue: ns.code) {
            switch code {
            case .quotaExceeded: return .quotaExceeded
            case .notAuthenticated: return .noAccount
            case .networkUnavailable, .networkFailure: return .offline
            case .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost, .operationCancelled:
                return nil
            case .partialFailure:
                let parts = (ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error])?.values.map { $0 } ?? []
                let mapped = parts.compactMap { classify($0) }
                for preferred in [Status.quotaExceeded, .noAccount, .offline] where mapped.contains(preferred) {
                    return preferred
                }
                return mapped.first
            default: return .unavailable
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return classify(underlying) }
        return .unavailable
    }

    /// Merge duplicates created on two devices, then replay the schedules that merge reset. Runs in its own context:
    /// a failure discards only the merge's unsaved changes (never the main context's unrelated edits), and the merge
    /// is retried after the next import or app open. No new cards for orphaned attempts here (app open only).
    @discardableResult
    static func merge(container: ModelContainer,
                      scheduler: Scheduler = Scheduler(examDate: SettingsKey.examDateValue)) -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { PreExamReviewPlanner.invalidate(context: container.mainContext) }
        do {
            try StudyDeduplication.run(context: context)
            try StudyReplay.run(context: context, scheduler: scheduler)
            return true
        } catch {
            context.rollback()
            Logger(subsystem: "org.example.optometryreview", category: "CloudSync")
                .error("Merge failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }
}
