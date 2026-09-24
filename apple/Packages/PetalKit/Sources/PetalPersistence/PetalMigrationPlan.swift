import SwiftData

enum PetalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PetalSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
