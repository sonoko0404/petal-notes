import Foundation
import SwiftData

enum PetalSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { PetalSchemaV1.models + [StoredSyncMetadata.self] }
    @Model final class StoredSyncMetadata {
        @Attribute(.unique) var key: String
        var payload: Data?
        init() { key = "sync"; payload = nil }
    }
}
