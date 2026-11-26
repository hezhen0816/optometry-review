#if DEBUG
import Foundation
import CoreData
import SwiftData

/// One-off DEBUG tool: creates the complete CloudKit development schema for every SwiftData model
/// (fields never saved non-nil are otherwise missing), so it can be deployed to Production.
/// Run once in a simulator signed in to iCloud: launch the Debug app with `-initCloudKitSchema`.
/// Uses a throwaway store; never touches default.store or icloud-debug.store.
enum CloudSchemaInit {
    static let argument = "-initCloudKitSchema"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(argument),
              let containerID = CloudSyncConfig.configuredContainerID, containerID.hasPrefix("iCloud.") else { return }
        let result = run()
        print(result)
        fflush(stdout)
        exit(0)
    }

    private static func run() -> String {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV5.models) else {
            return "CloudSchemaInit: failed could not build managed object model"
        }
        print("CloudSchemaInit: entities " + model.entities.compactMap(\.name).sorted().joined(separator: ", "))
        fflush(stdout)

        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("schema-init-\(UUID().uuidString).store")
        defer { removeStoreFiles(storeURL) }

        let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: CloudSyncConfig.containerID)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { return "CloudSchemaInit: failed \(loadError)" }
        do {
            try container.initializeCloudKitSchema(options: [])
            return "CloudSchemaInit: success"
        } catch {
            return "CloudSchemaInit: failed \(error)"
        }
    }

    private static func removeStoreFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
#endif
