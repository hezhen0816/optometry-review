import Foundation
import SwiftData
import Observation
import OSLog

/// Original persistent definitions are frozen in SchemaV1Models.swift.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self, AIExplanation.self]
    }
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self, AIExplanation.self]
    }
}

enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self, AIExplanation.self]
    }
}

enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self, AIExplanation.self]
    }
}

/// V4 models are frozen copies (SchemaV4Models.swift) except QuestionNote and AIExplanation, which V5 shares.
/// 0.3.0 V5: new model `SavedNote` and synced identities (`cardID`, `createdByRepair`, `attemptID`, `syncID`), all
/// optional or defaulted, so V4 stores migrate lightweight. This is the first schema shipped to CloudKit; from here
/// on fields may only be added (optional or defaulted), never renamed or removed.
enum SchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [QuestionRecord.self, AttemptRecord.self, MockExam.self, FullMock.self, QuestionNote.self, AIExplanation.self,
         SavedNote.self]
    }
}

enum StudyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
         .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
         .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
         .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self)]
    }
}

/// Persistent recovery notice, exposed to the settings and startup UI. Acknowledging never removes backups.
@MainActor @Observable
final class DataStoreRecovery {
    static let shared = DataStoreRecovery()
    static let pendingKey = "dataStoreRecovery.pending"
    static let backupPathKey = "dataStoreRecovery.backupPath"
    static let inMemoryKey = "dataStoreRecovery.inMemory"
    static let backupCompleteKey = "dataStoreRecovery.backupComplete"

    private let defaults: UserDefaults
    private(set) var pending: Bool
    private(set) var backupPath: String?
    private(set) var usedInMemoryStore: Bool
    private(set) var backupComplete: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.bool(forKey: Self.pendingKey)
        backupPath = defaults.string(forKey: Self.backupPathKey)
        usedInMemoryStore = defaults.bool(forKey: Self.inMemoryKey)
        backupComplete = defaults.bool(forKey: Self.backupCompleteKey)
    }

    func acknowledge() {
        pending = false
        defaults.set(false, forKey: Self.pendingKey)
    }

    fileprivate func setInMemory(_ inMemory: Bool) {
        usedInMemoryStore = inMemory
        defaults.set(inMemory, forKey: Self.inMemoryKey)
    }

    fileprivate func record(backup: URL?, inMemory: Bool, complete: Bool) {
        pending = true
        backupPath = backup?.path
        usedInMemoryStore = inMemory
        backupComplete = complete
        defaults.set(true, forKey: Self.pendingKey)
        defaults.set(backupPath, forKey: Self.backupPathKey)
        defaults.set(inMemory, forKey: Self.inMemoryKey)
        defaults.set(complete, forKey: Self.backupCompleteKey)
    }
}

@MainActor
enum StudyDataStore {
    static var schema: Schema { Schema(versionedSchema: SchemaV5.self) }

    static func open(_ configuration: ModelConfiguration,
                     repair: (@MainActor (ModelContext) throws -> Void)? = nil) throws -> ModelContainer {
        let container = try ModelContainer(for: schema, migrationPlan: StudyMigrationPlan.self, configurations: [configuration])
        do {
            if let repair { try repair(container.mainContext) }
            else {
                try StudyDeduplication.run(context: container.mainContext, repairOrphans: true)
                try StudyReplay.run(context: container.mainContext,
                                    scheduler: Scheduler(examDate: SettingsKey.examDateValue))
            }
        } catch {
            // Discard unsaved repairs and their replay markers, so the next launch retries.
            container.mainContext.rollback()
            Logger(subsystem: "org.example.optometryreview", category: "StudyDataStore")
                .error("Post-open repair failed: \(String(describing: error), privacy: .private)")
        }
        return container
    }

    static func makeContainer(inMemory: Bool = false, configuration: ModelConfiguration? = nil,
                              recovery: DataStoreRecovery? = nil, now: Date = .now,
                              repair: (@MainActor (ModelContext) throws -> Void)? = nil,
                              opener: (@MainActor (ModelConfiguration) throws -> ModelContainer)? = nil) -> ModelContainer {
        let recovery = recovery ?? .shared
        let opener = opener ?? { try open($0, repair: repair) }
        let config = configuration ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        if config.isStoredInMemoryOnly {
            let container = try! opener(config)
            recovery.setInMemory(true)
            return container
        }
        do {
            let container = try opener(config)
            // A notice may survive a previous memory fallback; describe this launch's actual store.
            recovery.setInMemory(false)
            return container
        } catch {
            let fm = FileManager.default
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var folder = config.url.deletingLastPathComponent().appendingPathComponent("StoreBackups", isDirectory: true)
                .appendingPathComponent(formatter.string(from: now), isDirectory: true)
            if fm.fileExists(atPath: folder.path) { folder.appendPathComponent(UUID().uuidString, isDirectory: true) }
            var complete = true
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    let source = URL(fileURLWithPath: config.url.path + suffix)
                    if fm.fileExists(atPath: source.path) {
                        try fm.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
                    }
                }
            } catch { complete = false }
            // Never retry against a partially moved store. Preserve remaining files and use memory instead.
            if complete, let fresh = try? opener(config) {
                recovery.record(backup: folder, inMemory: false, complete: true)
                return fresh
            }
            recovery.record(backup: folder, inMemory: true, complete: complete)
            // With a valid frozen schema, an in-memory container does not depend on storage availability.
            return try! opener(ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
    }

    /// The on-disk store without iCloud (same file the iCloud configuration uses).
    static var localConfiguration: ModelConfiguration {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    }

    static func cloudConfiguration(url: URL) -> ModelConfiguration {
        ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(CloudSyncConfig.containerID))
    }

    /// App entry point. With `cloud`, opens the store mirrored to the private iCloud database after the one-time
    /// first-sync backup. If iCloud cannot open (backup failed, CloudKit setup throws), the same file is opened
    /// local-only through `makeContainer`; only if that also fails does its usual corrupt-store recovery run
    /// (which moves the file to StoreBackups). An iCloud failure alone never moves the file.
    /// `local` defaults to `CloudSyncConfig.storeConfiguration(cloud:)`. Returns whether iCloud sync is on.
    static func makeAppContainer(inMemory: Bool, cloud: Bool, defaults: UserDefaults = .standard, now: Date = .now,
                                 local: ModelConfiguration? = nil, recovery: DataStoreRecovery? = nil,
                                 backup: ((URL) -> Bool)? = nil,
                                 cloudOpener: (@MainActor (ModelConfiguration) throws -> ModelContainer)? = nil)
        -> (container: ModelContainer, syncing: Bool) {
        let recovery = recovery ?? .shared
        if inMemory { return (makeContainer(inMemory: true, recovery: recovery), false) }
        let local = local ?? CloudSyncConfig.storeConfiguration(cloud: cloud)
        guard cloud else { return (makeContainer(configuration: local, recovery: recovery), false) }
        let backedUp = backup?(local.url) ?? FirstSyncBackup.ensure(storeURL: local.url, defaults: defaults, now: now)
        guard backedUp else { return (makeContainer(configuration: local, recovery: recovery), false) }
        do {
            let container = try (cloudOpener ?? { try open($0) })(cloudConfiguration(url: local.url))
            recovery.setInMemory(false)
            return (container, true)
        } catch {
            Logger(subsystem: "org.example.optometryreview", category: "StudyDataStore")
                .error("iCloud store did not open, using local only: \(String(describing: error), privacy: .private)")
            return (makeContainer(configuration: local, recovery: recovery), false)
        }
    }

    #if DEBUG
    /// Simulator-only fault injection; executed before SwiftData opens the file.
    static func corruptStoreIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-corruptStore") else { return }
        let url = ModelConfiguration(schema: schema).url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("Debug corrupt store".utf8).write(to: url, options: .atomic)
    }
    #endif
}
