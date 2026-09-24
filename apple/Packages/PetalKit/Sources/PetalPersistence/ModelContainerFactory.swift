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
        let schema = Schema(versionedSchema: PetalSchemaV1.self)
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
        let coordinator = StoreCoordinator(lockURL: directory.appendingPathComponent("Petal.lock"))
        try coordinator.validateSchema()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try coordinator.withLock {
            let marker = directory.appendingPathComponent("Petal.schema-version")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("1".utf8).write(to: marker, options: .atomic)
            }
            let schema = Schema(versionedSchema: PetalSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema,
                url: directory.appendingPathComponent("Petal.sqlite"), cloudKitDatabase: .none)
            return PetalStore(container: try ModelContainer(
                for: schema, migrationPlan: PetalMigrationPlan.self, configurations: [configuration]
            ), coordinator: coordinator)
        }
    }
}

/// Serializes each handle in-process and all cooperating App/Widget writers across processes.
final class StoreCoordinator: Sendable {
    private let lock = NSLock()
    private let lockURL: URL?
    init(lockURL: URL? = nil) { self.lockURL = lockURL }

    // A missing/malformed marker on an existing store fails closed. Future migrations
    // must advance this marker while holding the same lock, before opening for writes.
    func validateSchema() throws {
        guard let directory = lockURL?.deletingLastPathComponent() else { return }
        let marker = directory.appendingPathComponent("Petal.schema-version")
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let version = try? JSONDecoder().decode(Int.self, from: Data(contentsOf: marker)) else {
                throw RepositoryError.unrecognizedStoreSchema
            }
            guard version == 1 else { throw RepositoryError.unsupportedSchema(version) }
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
