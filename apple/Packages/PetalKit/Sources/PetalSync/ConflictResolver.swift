import PetalPersistence

/// The same deterministic rule is used inside the persistence transaction.
public typealias ConflictResolver = SyncConflictResolver
