import Foundation
import SwiftData
import CloudKit
import OSLog
import UIKit
import SQLite3

/// The first launch with iCloud on each device decides, before sync is turned on, what happens to the data already on
/// this device when iCloud already holds another device's data:
/// - this device has no answers → sync and download;
/// - iCloud is empty → this device is the first one and uploads;
/// - both have answers → she chooses: use iCloud's (this device's answers are exported and the store moved aside)
///   or merge both;
/// - the check cannot finish (offline, not signed in, timeout, CloudKit error) → stay local-only this launch and try
///   again next launch. Never merge on an unknown answer.
/// The decision is stored once per device (per store file).
enum FirstJoin {
    enum Decision: String {
        /// iCloud was empty: this device uploaded first.
        case first
        /// This device had no answers: it took iCloud's.
        case empty
        /// Replaced this device's answers with iCloud's (exported first).
        case useICloud
        /// Merged both sides.
        case merge

        /// 設定 › 資料, under the sync status.
        var settingsText: String {
            switch self {
            case .first: "這台是第一台開始同步的裝置"
            case .empty: "這台開始同步時沒有紀錄，使用 iCloud 上的紀錄"
            case .useICloud: "這台開始同步時改用了 iCloud 上的紀錄"
            case .merge: "這台開始同步時合併了兩邊的紀錄"
            }
        }
    }

    enum ProbeResult: Equatable {
        case hasData(Bool)
        /// The check could not finish; the status to show (等待網路／未登入 iCloud／目前無法同步).
        case undetermined(CloudSync.Status)
    }

    /// What the launch does next.
    enum Outcome: Equatable {
        case enable(Decision)
        case ask(local: Int, remote: Int?, recommendICloud: Bool)
        case stayLocal(CloudSync.Status)
    }

    /// Written by every syncing device at launch, read by a joining device for the number in the question.
    struct Record: Equatable {
        static let key = "cloudSync.joinRecord"
        var device: String
        var attempts: Int
        var date: Date

        var dictionary: [String: Any] { ["device": device, "attempts": attempts, "date": date.timeIntervalSince1970] }

        init(device: String, attempts: Int, date: Date) {
            self.device = device; self.attempts = attempts; self.date = date
        }

        init?(_ value: Any?) {
            guard let d = value as? [String: Any], let attempts = (d["attempts"] as? NSNumber)?.intValue else { return nil }
            device = d["device"] as? String ?? ""
            self.attempts = attempts
            date = Date(timeIntervalSince1970: (d["date"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    static let probeTimeout: TimeInterval = 10

    static func decisionKey(_ storeURL: URL) -> String { "cloudSync.join." + storeURL.lastPathComponent }
    static let exportPathKey = "cloudSync.join.exportPath"

    static func decision(storeURL: URL, defaults: UserDefaults = .standard) -> Decision? {
        defaults.string(forKey: decisionKey(storeURL)).flatMap(Decision.init(rawValue:))
    }

    static func save(_ decision: Decision, storeURL: URL, defaults: UserDefaults = .standard) {
        defaults.set(decision.rawValue, forKey: decisionKey(storeURL))
    }

    /// 建議「改用 iCloud」 when this device has clearly less: under 50 answers, or under half of iCloud's.
    static func recommendICloud(local: Int, remote: Int?) -> Bool {
        local < 50 || remote.map { local * 2 < $0 } ?? false
    }

    static func decide(localAttempts: Int, probe: ProbeResult, remote: Record?) -> Outcome {
        if localAttempts == 0 { return .enable(.empty) }
        switch probe {
        case .undetermined(let status): return .stayLocal(status)
        case .hasData(false): return .enable(.first)
        case .hasData(true):
            return .ask(local: localAttempts, remote: remote?.attempts,
                        recommendICloud: recommendICloud(local: localAttempts, remote: remote?.attempts))
        }
    }

    // MARK: Local store

    /// Answers in the store file (0 when there is no file). Opens the file local-only and closes it again.
    @MainActor
    static func localAttemptCount(storeURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return 0 }
        let config = ModelConfiguration(schema: StudyDataStore.schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: StudyDataStore.schema, migrationPlan: StudyMigrationPlan.self,
                                           configurations: [config])
        return try container.mainContext.fetchCount(FetchDescriptor<AttemptRecord>())
    }

    /// 「改用 iCloud 上的紀錄」: export this device's data and move the store files (not delete) into
    /// `StoreBackups/replaced-by-icloud-<time>/`, so a fresh store downloads iCloud's. Returns the export file.
    ///
    /// The export path is saved (`exportPathKey`) as soon as the export exists, before anything moves. The store is
    /// closed and its WAL checkpointed before moving; if any move fails, the files already moved are moved back and
    /// the error is rethrown, so the store is either fully in place or fully aside. `move` is injectable for tests.
    @MainActor
    static func replaceLocalStore(storeURL: URL, now: Date = .now, defaults: UserDefaults = .standard,
                                  move: ((URL, URL) throws -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        let move = move ?? { try fm.moveItem(at: $0, to: $1) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var folder = storeURL.deletingLastPathComponent().appendingPathComponent("StoreBackups", isDirectory: true)
            .appendingPathComponent("replaced-by-icloud-" + formatter.string(from: now), isDirectory: true)
        if fm.fileExists(atPath: folder.path) { folder.appendPathComponent(UUID().uuidString, isDirectory: true) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let export: URL = try autoreleasepool {
            let config = ModelConfiguration(schema: StudyDataStore.schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: StudyDataStore.schema, migrationPlan: StudyMigrationPlan.self,
                                               configurations: [config])
            return try StudyExport.makeFile(context: container.mainContext, now: now, folder: folder, logUsage: false)
        }
        defaults.set(export.path, forKey: exportPathKey)
        checkpoint(storeURL)
        var moved: [(from: URL, to: URL)] = []
        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = folder.appendingPathComponent(source.lastPathComponent)
                try move(source, target)
                moved.append((source, target))
            }
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
        return export
    }

    /// Folds the WAL into the main file and truncates it, so moving the files cannot split a transaction.
    static func checkpoint(_ storeURL: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(db)
    }

    static func preparedKey(_ storeURL: URL) -> String { "cloudSync.prepared." + storeURL.lastPathComponent }

    /// Before the store is ever opened with CloudKit: on a local-only container, fill the synced IDs of rows from
    /// before 0.3.0, cut their times to whole milliseconds, merge duplicates and replay, then close it. Once per store
    /// file; a missing file has nothing to prepare. Returns false (sync stays off this launch) on failure.
    @MainActor
    static func prepareForSync(storeURL: URL, defaults: UserDefaults = .standard,
                               scheduler: Scheduler = Scheduler(examDate: SettingsKey.examDateValue)) -> Bool {
        let key = preparedKey(storeURL)
        if defaults.bool(forKey: key) { return true }
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                try autoreleasepool {
                    let config = ModelConfiguration(schema: StudyDataStore.schema, url: storeURL, cloudKitDatabase: .none)
                    let container = try ModelContainer(for: StudyDataStore.schema, migrationPlan: StudyMigrationPlan.self,
                                                       configurations: [config])
                    try StudyDeduplication.run(context: container.mainContext, repairOrphans: true)
                    try StudyReplay.run(context: container.mainContext, scheduler: scheduler)
                }
            } catch {
                Logger(subsystem: "org.example.optometryreview", category: "CloudSync")
                    .error("Prepare for sync failed: \(String(describing: error), privacy: .private)")
                return false
            }
        }
        defaults.set(true, forKey: key)
        return true
    }

    // MARK: iCloud probe

    /// Asks CloudKit directly whether the Core Data mirroring zone exists and holds any record.
    static func probeCloudKit() async -> ProbeResult {
        let container = CKContainer(identifier: CloudSyncConfig.containerID)
        do {
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount: return .undetermined(.noAccount)
            default: return .undetermined(.unavailable)
            }
            let database = container.privateCloudDatabase
            let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
            do {
                _ = try await database.recordZone(for: zoneID)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                return .hasData(false)
            }
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: nil, desiredKeys: [],
                                                               resultsLimit: 1)
            return .hasData(!changes.modificationResultsByID.isEmpty || changes.moreComing)
        } catch {
            return .undetermined(CloudSync.classify(error) ?? .unavailable)
        }
    }

    /// Runs `probe`, answering「等待網路」 if it takes longer than `timeout` (the probe itself is left to finish).
    static func probe(timeout: TimeInterval = probeTimeout,
                      _ probe: @escaping @Sendable () async -> ProbeResult) async -> ProbeResult {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                let result = await probe()
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: .undetermined(.offline)) }
            }
        }
    }

    // MARK: Join record

    static func remoteRecord(store: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default) -> Record? {
        store.synchronize()
        return Record(store.object(forKey: Record.key))
    }

    @MainActor
    static func writeRecord(context: ModelContext, store: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default,
                            now: Date = .now) {
        // A device that has not downloaded yet has 0: skip, or it would hide the real count from the next device.
        guard let attempts = try? context.fetchCount(FetchDescriptor<AttemptRecord>()), attempts > 0 else { return }
        store.set(Record(device: UIDevice.current.model, attempts: attempts, date: now).dictionary, forKey: Record.key)
        store.synchronize()
    }
}

/// Opens the app's store, running the first-join decision when this device has not made it yet.
@MainActor @Observable
final class AppStoreLoader {
    enum Phase {
        case ready(ModelContainer)
        case checking
        case asking(local: Int, remote: Int?, recommendICloud: Bool)
    }

    enum Choice { case useICloud, merge }

    private(set) var phase: Phase = .checking
    @ObservationIgnored private let cloud: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onReady: @MainActor (ModelContainer, Bool) -> Void
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let probe: @Sendable () async -> FirstJoin.ProbeResult

    init(inMemory: Bool, cloud: Bool, defaults: UserDefaults = .standard,
         probe: @escaping @Sendable () async -> FirstJoin.ProbeResult = { await FirstJoin.probeCloudKit() },
         onReady: @escaping @MainActor (ModelContainer, Bool) -> Void) {
        self.cloud = cloud
        self.defaults = defaults
        self.onReady = onReady
        self.probe = probe
        storeURL = CloudSyncConfig.storeConfiguration(cloud: cloud).url
        if inMemory || !cloud || FirstJoin.decision(storeURL: storeURL, defaults: defaults) != nil {
            open(cloud: cloud && !inMemory, inMemory: inMemory)
            return
        }
        // Undecided: the one-time backup comes first; without it nothing else happens this launch.
        guard FirstSyncBackup.ensure(storeURL: storeURL, defaults: defaults) else {
            open(cloud: false, inMemory: false, status: .unavailable)
            return
        }
        let local: Int
        do { local = try FirstJoin.localAttemptCount(storeURL: storeURL) } catch {
            // Unreadable store: the normal open runs the corrupt-store recovery; decide on a later launch.
            open(cloud: false, inMemory: false, status: .unavailable)
            return
        }
        if local == 0 {
            FirstJoin.save(.empty, storeURL: storeURL, defaults: defaults)
            open(cloud: true, inMemory: false)
            return
        }
        Task { await self.check(local: local) }
    }

    private func check(local: Int) async {
        let result = await FirstJoin.probe(probe)
        let remote = FirstJoin.remoteRecord()
        switch FirstJoin.decide(localAttempts: local, probe: result, remote: remote) {
        case .enable(let decision):
            FirstJoin.save(decision, storeURL: storeURL, defaults: defaults)
            open(cloud: true, inMemory: false)
        case .stayLocal(let status):
            open(cloud: false, inMemory: false, status: status)
        case let .ask(local, remote, recommend):
            phase = .asking(local: local, remote: remote, recommendICloud: recommend)
        }
    }

    func choose(_ choice: Choice) {
        guard case .asking = phase else { return }
        switch choice {
        case .merge:
            FirstJoin.save(.merge, storeURL: storeURL, defaults: defaults)
        case .useICloud:
            do {
                _ = try FirstJoin.replaceLocalStore(storeURL: storeURL, defaults: defaults)
                FirstJoin.save(.useICloud, storeURL: storeURL, defaults: defaults)
            } catch {
                // The store files are back in place (moves are rolled back; a failed export moves nothing), but an
                // export may already exist in StoreBackups. Keep this device local and ask again next launch.
                Logger(subsystem: "org.example.optometryreview", category: "CloudSync")
                    .error("Replace local store failed: \(String(describing: error), privacy: .private)")
                open(cloud: false, inMemory: false, status: .unavailable)
                return
            }
        }
        open(cloud: true, inMemory: false)
    }

    private func open(cloud: Bool, inMemory: Bool, status: CloudSync.Status? = nil) {
        // Every path that turns sync on: the backup, then IDs, whole-millisecond times and merges written while the
        // store is still local-only, so the first upload already carries them.
        if cloud && !inMemory,
           !(FirstSyncBackup.ensure(storeURL: storeURL, defaults: defaults)
             && FirstJoin.prepareForSync(storeURL: storeURL, defaults: defaults)) {
            open(cloud: false, inMemory: false, status: .unavailable)
            return
        }
        let opened = StudyDataStore.makeAppContainer(inMemory: inMemory, cloud: cloud, defaults: defaults,
                                                     local: inMemory ? nil : CloudSyncConfig.storeConfiguration(cloud: self.cloud))
        if let status { CloudSync.shared.showLocalOnly(status) }
        if self.cloud { CloudSync.shared.joinDecision = FirstJoin.decision(storeURL: storeURL, defaults: defaults) }
        phase = .ready(opened.container)
        onReady(opened.container, opened.syncing)
    }
}
