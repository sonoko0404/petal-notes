import SwiftData

enum PetalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PetalSchemaV1.self, PetalSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: PetalSchemaV1.self, toVersion: PetalSchemaV2.self)] }
}
