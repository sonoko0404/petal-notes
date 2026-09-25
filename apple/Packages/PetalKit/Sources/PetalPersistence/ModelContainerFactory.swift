import Foundation
import SwiftData
import Darwin

/// Opaque store handle: clients never receive a ModelContext or a stored model.
public struct PetalStore: Sendable {
    let container: ModelContainer
    let coordinator: StoreCoordinator
}

public enum ModelContainerFactory {
    public static func makeInMemory() throws -> PetalStore {
        let schema = Schema(versionedSchema: PetalSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return PetalStore(container: try ModelContainer(
            for: schema, migrationPlan: PetalMigrationPlan.self, configurations: [configuration]
        ), coordinator: StoreCoordinator())
    }

    /// The resolver is injectable so App/Widget sharing is tested without signed entitlements.
    public static func makeShared(
        appGroupID: String,
        containerURL: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) throws -> PetalStore {
        guard !appGroupID.isEmpty, let root = containerURL(appGroupID) else {
            throw RepositoryError.appGroupUnavailable
        }
        let directory = root.appendingPathComponent("Library/Application Support/Petal", isDirectory: true)
        let coordinator = StoreCoordinator(lockURL: directory.appendingPathComponent("Petal.lock"),
            cacheURL: root.appendingPathComponent("Library/Caches/Petal/WidgetSnapshots", isDirectory: true))
        try coordinator.validateSchema()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try coordinator.withLock {
            let marker = directory.appendingPathComponent("Petal.schema-version")
            if (try? String(contentsOf: marker, encoding: .utf8)) == "1" {
                try writeRecoverySnapshot(directory: directory)
            }
            // Fence old processes before migration. A failed migration can be
            // retried by v2, while v1 must refuse any further writes.
            try Data("2".utf8).write(to: marker, options: .atomic)
            let schema = Schema(versionedSchema: PetalSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema,
                url: directory.appendingPathComponent("Petal.sqlite"), cloudKitDatabase: .none)
            return PetalStore(container: try ModelContainer(
                for: schema, migrationPlan: PetalMigrationPlan.self, configurations: [configuration]
            ), coordinator: coordinator)
        }
    }

    private static func writeRecoverySnapshot(directory: URL) throws {
        let schema = Schema(versionedSchema: PetalSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("Petal.sqlite"), cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let payloads: [String: [Data]] = [
            "cards": try context.fetch(FetchDescriptor<PetalSchemaV1.StoredCard>()).map(\.payload),
            "lines": try context.fetch(FetchDescriptor<PetalSchemaV1.StoredLine>()).map(\.payload),
            "outbox": try context.fetch(FetchDescriptor<PetalSchemaV1.StoredOutboxChange>()).map(\.payload),
            "conflicts": try context.fetch(FetchDescriptor<PetalSchemaV1.StoredConflictArtifact>()).map(\.payload)
        ]
        try JSONEncoder().encode(payloads).write(to: directory.appendingPathComponent("Petal.pre-v2-recovery.json"), options: .atomic)
    }
}

/// Serializes each handle in-process and all cooperating App/Widget writers across processes.
final class StoreCoordinator: Sendable {
    private let lock = NSLock()
    private let lockURL: URL?
    private let cacheURL: URL?
    init(lockURL: URL? = nil, cacheURL: URL? = nil) { self.lockURL = lockURL; self.cacheURL = cacheURL }

    func installWidgetResetFence(generation: UUID) throws {
        if let cacheURL { try WidgetSnapshotCache.installResetFence(at: cacheURL, generation: generation) }
    }

    func eraseWidgetSnapshots() throws {
        if let cacheURL { try WidgetSnapshotCache.eraseSnapshots(at: cacheURL) }
    }

    func publishCommit() {
        NotificationCenter.default.post(name: .petalRepositoryDidCommit, object: nil)
        publishCrossProcessCommit()
    }

    func publishCrossProcessCommit() {
        guard lockURL != nil else { return }
        // Wake the foreground app after Widget/intent writes. The signal carries
        // no content; consumers always re-read the shared repository.
        DistributedNotificationCenter.default().postNotificationName(.petalRepositoryDidCommit,
            object: String(ProcessInfo.processInfo.processIdentifier), userInfo: nil, deliverImmediately: true)
    }

    func removeMigrationRecoverySnapshot() throws {
        guard let directory = lockURL?.deletingLastPathComponent() else { return }
        let file = directory.appendingPathComponent("Petal.pre-v2-recovery.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    // A missing/malformed marker on an existing store fails closed. Future migrations
    // must advance this marker while holding the same lock, before opening for writes.
    func validateSchema() throws {
        guard let directory = lockURL?.deletingLastPathComponent() else { return }
        let marker = directory.appendingPathComponent("Petal.schema-version")
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let version = try? JSONDecoder().decode(Int.self, from: Data(contentsOf: marker)) else {
                throw RepositoryError.unrecognizedStoreSchema
            }
            guard version == 1 || version == 2 else { throw RepositoryError.unsupportedSchema(version) }
        } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Petal.sqlite").path) {
            throw RepositoryError.unrecognizedStoreSchema
        }
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try validateSchema()
        guard let lockURL else { return try body() }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        try validateSchema()
        return try body()
    }
}
