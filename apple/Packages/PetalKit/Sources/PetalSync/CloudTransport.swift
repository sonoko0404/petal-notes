import Foundation
import PetalPersistence

public enum CloudTransportError: Error, Sendable, Equatable {
    case networkUnavailable, authenticationRequired, quotaExceeded, accountUnavailable, invalidRecord, conflict, unavailable
    case retryAfter(TimeInterval)
}

public struct OutboundCloudChange: Sendable {
    public let record: ReplicatedRecord
    public let journal: [OutboxChange]
    public var id: UUID { journal.last!.id }
}

public protocol CloudTransport: Sendable {
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult
    func cancel() async
}
public extension CloudTransport { func cancel() async {} }

public struct CloudFetchResult: Sendable {
    public let records: [ReplicatedRecord]
    public let token: Data?
    public init(records: [ReplicatedRecord], token: Data?) { self.records = records; self.token = token }
}

public struct CloudSendResult: Sendable {
    public let acceptedIDs: Set<UUID>
    public let token: Data?
    public init(acceptedIDs: Set<UUID>, token: Data? = nil) { self.acceptedIDs = acceptedIDs; self.token = token }
}
